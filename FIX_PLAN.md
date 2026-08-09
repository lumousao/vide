# VIDE 修复计划 - 实时外部更新优化

**目标**: 确保用户能够实时、可靠地看到agent在工作过程中对文件的所有修改

**优先级**: 关键 (P0) - 这是项目的核心功能

---

## 问题分析

### 当前行为分析

根据代码审查，当前的外部更改检测流程：

```
外部文件修改 → inotify事件 → vide-watch → Vim异步回调 
→ HandleChangedPath → 更新快照 → 渲染树 → 在编辑器中打开文件
```

### 已识别的问题

1. **FileChangedShell 静默保留本地更改** (严重)
   - 位置: `src/vide.vim:556-564`
   - 影响: 用户有未保存修改时，外部更改被静默忽略
   - 场景: Agent修改文件时，用户正在同一文件中工作

2. **ATTRIB 事件被过滤** (中等)
   - 位置: `src/vide.vim:1030-1038`
   - 影响: 某些文件更新可能被跳过
   - 场景: 文件内容未变但时间戳变化

3. **快照预算导致遗漏** (中等)
   - 位置: `src/vide.vim:796-813`
   - 影响: 大文件或预算耗尽时，不记录快照
   - 场景: Agent修改大文件或在大项目中工作

4. **事件批处理延迟** (轻微)
   - 位置: `src/vide.vim:1095-1097`
   - 影响: 20ms的延迟可能错过快速连续的更改
   - 场景: Agent快速连续保存多个文件

5. **ignore模式可能屏蔽重要文件** (轻微)
   - 位置: `src/vide.vim:49, 360-371`
   - 影响: 某些文件可能不被监控
   - 场景: Agent在node_modules或.git中的文件修改被忽略

---

## 修复方案

### Phase 1: 冲突处理改进 (关键)

**目标**: 确保用户总是能看到外部更改，即使有本地未保存内容

#### 1.1 增强 FileChangedShell 处理

**当前代码**:
```vim
function! s:FileChangedShell() abort
  if &modified
    let v:fcs_choice = 'use'
    call s:TreeError('external change detected; unsaved buffer preserved')
  else
    let v:fcs_choice = 'reload'
  endif
endfunction
```

**修复方案**:
```vim
function! s:FileChangedShell() abort
  let l:path = expand('<afile>:p')
  if &modified
    " 保留用户版本，但提供对比和合并选项
    let v:fcs_choice = 'use'
    let s:conflicts[l:path] = {
      \ 'time': localtime(),
      \ 'user_modified': 1,
      \ 'need_review': 1
    }
    " 在状态栏和树中显示冲突标记
    call s:MarkConflict(l:path)
    echohl WarningMsg
    echomsg 'CONFLICT: ' . fnamemodify(l:path, ':t') . ' - external change detected (press F5 to compare)'
    echohl None
    " 自动创建临时备份以便后续对比
    call s:SaveExternalVersion(l:path)
  else
    let v:fcs_choice = 'reload'
    call s:ClearConflict(l:path)
  endif
endfunction
```

#### 1.2 添加冲突可视化

```vim
" 新增：冲突标记管理
let s:conflicts = {}

function! s:MarkConflict(path) abort
  let s:conflicts[a:path] = 1
  " 在树中用特殊高亮标记冲突文件
  call s:Render()
  redrawstatus
endfunction

function! s:ClearConflict(path) abort
  if has_key(s:conflicts, a:path)
    call remove(s:conflicts, a:path)
    call s:Render()
    redrawstatus
  endif
endfunction

" 新增：保存外部版本到临时文件
function! s:SaveExternalVersion(path) abort
  let l:temp_path = s:GetConflictTempPath(a:path)
  try
    call mkdir(fnamemodify(l:temp_path, ':h'), 'p')
    call writefile(readfile(a:path, 'b'), l:temp_path, 'b')
  catch /^Vim\%((\a\+)\)\=:E/
    " 如果无法保存临时文件，至少记录错误
  endtry
endfunction

function! s:GetConflictTempPath(path) abort
  let l:hash = sha256(a:path)[:8]
  return stdpath('cache') . '/vide/conflicts/' . l:hash . '_' . fnamemodify(a:path, ':t')
endfunction

" 新增：对比冲突的命令
function! s:CompareConflict() abort
  let l:path = expand('%:p')
  if !has_key(s:conflicts, l:path)
    echomsg 'No conflict for this file'
    return
  endif
  let l:temp_path = s:GetConflictTempPath(l:path)
  if !filereadable(l:temp_path)
    echomsg 'External version not available'
    return
  endif
  " 使用垂直分屏对比
  execute 'vertical diffsplit ' . fnameescape(l:temp_path)
  setlocal readonly
  setlocal buftype=nofile
  wincmd p
endfunction

" 添加快捷键
nnoremap <silent> <F5> :<C-U>call <SID>CompareConflict()<CR>
```

#### 1.3 在状态栏显示冲突

```vim
" 修改状态栏配置，添加冲突指示
setlocal statusline=%#VideStatus#\ VIDE\ %*%<%{exists('b:vide_conflict')?'⚠\ CONFLICT\ ':''}%=%#VideStatusMeta#\ %{get(g:,\ 'vide_watch_backend',\ 'OFF')}\ %{get(g:,\ 'vide_notice',\ '')}\ \ %l/%L\ 
```

### Phase 2: 快照和事件处理优化 (高优先级)

#### 2.1 强制保留 agent 工作区文件的快照

**策略**: 为正在被修改的文件提供更高的快照优先级

```vim
" 新增：高优先级快照列表
let s:priority_paths = []

function! s:StoreSnapshot(path, contents) abort
  " ... 现有代码 ...
  
  " 高优先级文件不参与LRU淘汰
  let l:is_priority = index(s:priority_paths, a:path) >= 0
  if l:is_priority
    " 标记为高优先级，在预算清理时跳过
    let s:watch.snapshot_priorities[a:path] = 1
  endif
  
  " 修改预算清理逻辑
  while s:snapshot_bytes > s:snapshot_budget && !empty(s:watch.contents)
    let l:victim = remove(s:snapshot_order, 0)
    " 跳过高优先级文件
    if get(s:watch.snapshot_priorities, l:victim, 0)
      call add(s:snapshot_order, l:victim)
      continue
    endif
    let s:snapshot_bytes -= get(s:watch.snapshot_sizes, l:victim, 0)
    call remove(s:watch.snapshot_sizes, l:victim)
    call remove(s:watch.contents, l:victim)
  endwhile
endfunction

" 新增：自动检测频繁修改的文件
function! s:UpdatePriorityPaths() abort
  " 最近1分钟内修改超过3次的文件自动加入优先级列表
  let l:now = localtime()
  let s:priority_paths = []
  for [l:path, l:changes] in items(get(s:, 'recent_changes', {}))
    if l:now - l:changes.first < 60 && l:changes.count >= 3
      call add(s:priority_paths, l:path)
    endif
  endfor
endfunction
```

#### 2.2 减少事件批处理延迟

```vim
" 修改：更积极的事件处理
function! s:QueueChangedEvent(kind, path) abort
  if !exists('*timer_start')
    call s:HandleChangedPath(a:path, a:kind)
    return
  endif
  call add(s:pending_events, [a:kind, a:path])
  if s:event_timer < 0
    " 从20ms减少到5ms，更快响应
    let s:event_timer = timer_start(5, function('<SID>FlushChangedEvents'))
  endif
endfunction
```

#### 2.3 改进 ATTRIB 事件过滤

```vim
function! s:HandleChangedPath(path, kind) abort
  " ... 现有代码 ...
  
  " 修改 ATTRIB 过滤逻辑，确保总是检查内容
  if l:kind ==# 'ATTRIB'
    " 移除复杂的提前退出逻辑
    " 总是读取快照并比较hash
    let l:signature = getftime(l:path) . ':' . getfsize(l:path)
    let l:snapshot = s:ReadSnapshot(l:path)
    let l:hash = l:snapshot.hash
    
    " 如果hash相同，才跳过
    if has_key(s:watch.hashes, l:path) && 
          \ get(s:watch.hashes, l:path, '') ==# l:hash && 
          \ !empty(l:hash)
      return
    endif
    " hash不同，继续处理
  endif
  
  " ... 继续现有逻辑 ...
endfunction
```

### Phase 3: 通知和可见性改进 (中优先级)

#### 3.1 添加变更通知系统

```vim
" 新增：变更通知队列
let s:change_notifications = []
let s:notification_timer = -1

function! s:NotifyChange(path, kind) abort
  let l:display_path = fnamemodify(a:path, ':~:.')
  let l:message = printf('[%s] %s', a:kind, l:display_path)
  
  call add(s:change_notifications, {
    \ 'time': localtime(),
    \ 'path': a:path,
    \ 'kind': a:kind,
    \ 'message': l:message
  })
  
  " 限制队列长度
  if len(s:change_notifications) > 50
    call remove(s:change_notifications, 0)
  endif
  
  " 在状态栏显示最近的通知
  let g:vide_last_change = l:message
  redrawstatus
  
  " 如果开启了详细模式，使用echo显示
  if get(g:, 'vide_verbose_changes', 1)
    echomsg 'VIDE: ' . l:message
  endif
endfunction

" 在 HandleChangedPath 中调用
function! s:HandleChangedPath(path, kind) abort
  " ... 现有逻辑 ...
  
  " 在处理完成后通知
  call s:NotifyChange(l:path, l:kind)
endfunction

" 新增：查看变更历史的命令
function! s:ShowChangeHistory() abort
  let l:lines = ['Recent file changes:']
  for l:notif in reverse(copy(s:change_notifications))
    let l:time_str = strftime('%H:%M:%S', l:notif.time)
    call add(l:lines, printf('%s  %s', l:time_str, l:notif.message))
  endfor
  
  " 在新buffer中显示
  rightbelow new
  setlocal buftype=nofile bufhidden=wipe noswapfile
  call setline(1, l:lines)
  setlocal nomodifiable
  execute 'file [VIDE] Change History'
endfunction

nnoremap <silent> <C-H> :<C-U>call <SID>ShowChangeHistory()<CR>
```

#### 3.2 在树中高亮最近修改的文件

```vim
" 修改高亮组，添加"最近修改"样式
highlight default VideRecentChange cterm=bold ctermfg=Yellow gui=bold guifg=Yellow

" 跟踪最近5秒内的修改
let s:recent_changes = {}

function! s:MarkRecentChange(path) abort
  let s:recent_changes[a:path] = localtime()
  " 5秒后清除标记
  call timer_start(5000, {-> s:ClearRecentChange(a:path)})
endfunction

function! s:ClearRecentChange(path) abort
  if has_key(s:recent_changes, a:path)
    let l:age = localtime() - s:recent_changes[a:path]
    if l:age >= 5
      call remove(s:recent_changes, a:path)
      call s:Render()
    endif
  endif
endfunction

" 在渲染时应用高亮
function! s:ApplyRecentChangeHighlight() abort
  for l:node in get(b:, 'vide_nodes', [])
    if has_key(s:recent_changes, l:node.path)
      call matchaddpos('VideRecentChange', [[l:node.line, 1, -1]], 25)
    endif
  endfor
endfunction

" 在 HandleChangedPath 中标记
function! s:HandleChangedPath(path, kind) abort
  " ... 现有逻辑 ...
  call s:MarkRecentChange(l:path)
  " ...
endfunction
```

### Phase 4: 配置和用户控制 (低优先级)

#### 4.1 添加监控模式配置

```vim
" 新增设置选项
let s:settings = {
      \ 'sidebar_percent': 34,
      \ 'content_limit_kb': 256,
      \ 'snapshot_budget_kb': 8192,
      \ 'marker_style': 'auto',
      \ 'watch_mode': 'aggressive',  " aggressive | normal | minimal
      \ 'auto_reload': 1,             " 自动重载干净的buffer
      \ 'conflict_strategy': 'ask',   " ask | keep-local | keep-external
      \ 'verbose_changes': 1          " 显示详细的变更通知
      \ }

" 根据watch_mode调整行为
function! s:GetWatchBehavior() abort
  let l:mode = get(s:settings, 'watch_mode', 'normal')
  if l:mode ==# 'aggressive'
    return {
      \ 'event_delay_ms': 5,
      \ 'force_reload': 1,
      \ 'ignore_attrib': 0,
      \ 'show_all_changes': 1
      \ }
  elseif l:mode ==# 'minimal'
    return {
      \ 'event_delay_ms': 50,
      \ 'force_reload': 0,
      \ 'ignore_attrib': 1,
      \ 'show_all_changes': 0
      \ }
  else
    return {
      \ 'event_delay_ms': 20,
      \ 'force_reload': 0,
      \ 'ignore_attrib': 0,
      \ 'show_all_changes': 1
      \ }
  endif
endfunction
```

#### 4.2 添加手动刷新命令

```vim
" 新增：强制刷新所有文件
function! s:ForceRefreshAll() abort
  call s:TreeMessage('Refreshing all files...')
  let l:count = 0
  for l:path in keys(s:watch.contents)
    let l:snapshot = s:ReadSnapshot(l:path)
    let l:old_hash = get(s:watch.hashes, l:path, '')
    if l:snapshot.hash !=# l:old_hash
      call s:HandleChangedPath(l:path, 'WRITE')
      let l:count += 1
    endif
  endfor
  call s:TreeMessage(printf('Refreshed: %d file(s) changed', l:count))
endfunction

nnoremap <silent> <F6> :<C-U>call <SID>ForceRefreshAll()<CR>
```

---

## 实施计划

### Week 1: Phase 1 - 冲突处理 (最关键)

**Day 1-2**: 
- [ ] 实现增强的 FileChangedShell
- [ ] 添加冲突标记系统
- [ ] 实现临时文件保存

**Day 3-4**:
- [ ] 实现对比视图 (F5)
- [ ] 添加冲突可视化（状态栏、树标记）
- [ ] 测试各种冲突场景

**Day 5**:
- [ ] 编写测试用例
- [ ] 文档更新
- [ ] 用户测试

### Week 2: Phase 2 - 快照和事件优化

**Day 1-2**:
- [ ] 实现高优先级快照系统
- [ ] 优化快照预算管理
- [ ] 减少事件批处理延迟

**Day 3-4**:
- [ ] 改进 ATTRIB 事件处理
- [ ] 实现自动优先级检测
- [ ] 性能测试和调优

**Day 5**:
- [ ] 测试大文件和大项目场景
- [ ] 压力测试
- [ ] Bug修复

### Week 3: Phase 3 - 通知系统

**Day 1-2**:
- [ ] 实现变更通知队列
- [ ] 添加变更历史查看器
- [ ] 实现最近修改高亮

**Day 3-4**:
- [ ] 集成所有通知点
- [ ] UI/UX 优化
- [ ] 可配置性

**Day 5**:
- [ ] 用户测试
- [ ] 收集反馈
- [ ] 调整

### Week 4: Phase 4 - 配置和完善

**Day 1-2**:
- [ ] 实现监控模式配置
- [ ] 添加手动刷新命令
- [ ] 设置界面更新

**Day 3-4**:
- [ ] 完整的集成测试
- [ ] 性能基准测试
- [ ] 文档完善

**Day 5**:
- [ ] 最终测试
- [ ] Release notes
- [ ] 部署准备

---

## 测试场景

### 关键测试用例

1. **Agent 快速连续修改多个文件**
   ```bash
   # 模拟agent工作
   for i in {1..10}; do
     echo "change $i" >> test.txt
     sleep 0.1
   done
   ```
   期望: 所有10次修改都被检测和显示

2. **用户正在编辑时 agent 修改同一文件**
   ```
   1. 用户打开 file.txt 并修改（不保存）
   2. Agent 外部修改 file.txt
   3. 期望: 显示冲突警告，提供对比选项
   ```

3. **大文件修改**
   ```bash
   # 创建5MB文件
   dd if=/dev/urandom of=large.bin bs=1M count=5
   # 修改
   echo "changed" >> large.bin
   ```
   期望: 即使超过快照限制，也应检测到变化

4. **快速删除和重建文件**
   ```bash
   rm test.txt && echo "new" > test.txt
   ```
   期望: 正确处理DELETE和CREATE事件

5. **目录树的大规模变化**
   ```bash
   # 解压大压缩包
   tar -xzf large-project.tar.gz
   ```
   期望: 不遗漏文件，不崩溃

---

## 性能指标

### 目标

- 事件响应延迟: < 10ms (从inotify到Vim处理)
- UI 刷新延迟: < 50ms (从处理到树重绘)
- 大项目 (10k+ 文件) 启动: < 5秒
- 内存使用: < 100MB (1000个活动文件)

### 监控

添加性能日志：

```vim
let g:vide_perf_stats = {
  \ 'events_processed': 0,
  \ 'avg_event_latency_ms': 0,
  \ 'conflicts_detected': 0,
  \ 'snapshots_active': 0,
  \ 'memory_bytes': 0
  \ }

function! s:UpdatePerfStats(event_start) abort
  let g:vide_perf_stats.events_processed += 1
  let l:latency = reltimefloat(reltime(a:event_start)) * 1000
  let l:count = g:vide_perf_stats.events_processed
  let g:vide_perf_stats.avg_event_latency_ms = 
    \ (g:vide_perf_stats.avg_event_latency_ms * (l:count - 1) + l:latency) / l:count
endfunction
```

---

## 风险评估

### 高风险区域

1. **FileChangedShell 修改**
   - 风险: 可能破坏现有工作流
   - 缓解: 充分测试，提供回退选项

2. **事件处理延迟减少**
   - 风险: 可能增加CPU使用
   - 缓解: 性能测试，可配置

3. **快照优先级系统**
   - 风险: 复杂的内存管理可能引入bug
   - 缓解: 渐进式实施，大量测试

### 回退策略

每个Phase完成后打tag：
- `v0.2.0-phase1-conflict-handling`
- `v0.2.0-phase2-event-optimization`
- `v0.2.0-phase3-notifications`
- `v0.2.0-final`

如果出现严重问题，可以回退到上一个稳定的Phase。

---

## 成功标准

### Phase 1 完成标准
- [ ] 100% 外部修改都会通知用户（即使有本地修改）
- [ ] 提供清晰的冲突对比界面
- [ ] 无数据丢失

### Phase 2 完成标准
- [ ] 事件响应延迟 < 10ms
- [ ] 大文件修改不遗漏
- [ ] 快照系统稳定

### Phase 3 完成标准
- [ ] 所有修改都有清晰的视觉反馈
- [ ] 变更历史可追溯
- [ ] UI 不干扰正常工作

### Phase 4 完成标准
- [ ] 用户可以根据需求调整监控强度
- [ ] 文档完整
- [ ] 所有测试通过

---

## 后续改进

完成上述4个Phase后，可以考虑：

1. **智能变更分组**
   - 将相关的文件修改分组显示（如git commit的概念）

2. **变更预览**
   - 在树中直接显示diff预览（不需要打开文件）

3. **远程协作支持**
   - 显示谁在修改文件（如果是多人协作）

4. **机器学习辅助**
   - 学习用户的工作模式，预测需要关注的文件

5. **与版本控制集成**
   - 结合git status显示更丰富的信息

---

## 总结

这个修复计划专注于确保**实时外部更新的可靠性和可见性**，特别针对监控agent工作的场景。

核心改进：
1. ✅ 永远不会静默丢弃外部更改
2. ✅ 冲突情况下提供清晰的对比和选择
3. ✅ 所有变更都有视觉反馈
4. ✅ 可配置的监控强度

预计完成时间：**4周**  
风险级别：**中等**（主要是测试工作量）  
建议：**渐进式部署，每个Phase独立测试后再进入下一个**
