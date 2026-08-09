# VIDE 完善修复计划

基于代码审查结果，本文档提供了一个分阶段的改进路线图，涵盖安全性、性能、可维护性和跨平台支持。

---

## 阶段 1：关键安全修复（1-2 周）

### 1.1 消除 TOCTOU 竞态条件

**问题**: `src/vide.vim` 中的双重验证在检查和使用之间创建了竞态窗口

**当前代码** (`src/vide.vim:537-540`):
```vim
if empty(s:SafeChildPath(l:parent, l:name))
  call s:TreeError('path changed or now contains a symbolic link')
  return
endif
let l:operation = l:kind == 1 ? 'create-file' : 'create-dir'
if !s:FsCall(l:operation, [l:path])
  return
endif
```

**修复方案**:
- 移除 Vim 端的第二次 `SafeChildPath` 调用
- 让 `vide-fs` 成为唯一的验证和执行点
- `vide-fs` 已通过描述符操作提供原子性保证

**文件**: `src/vide.vim:517-553`, `src/vide.vim:583-624`

**实现**:
```vim
function! s:CreateNode() abort
  let l:node = s:NodeAtCursor()
  if empty(l:node)
    return
  endif
  let l:parent = l:node.dir ? l:node.path : fnamemodify(l:node.path, ':h')
  let l:name = input('Create relative path: ')
  let l:path = s:SafeChildPath(l:parent, l:name)
  if empty(l:path)
    call s:TreeError('path must stay inside the project')
    return
  endif
  " 移除重复检查 - 让 vide-fs 处理所有验证
  let l:kind = confirm('Create ' . fnamemodify(l:path, ':t') . ' as:', "&File\n&Directory\n&Cancel", 3)
  if l:kind == 3 || l:kind == 0
    return
  endif
  let l:operation = l:kind == 1 ? 'create-file' : 'create-dir'
  if !s:FsCall(l:operation, [l:path])
    return
  endif
  " ... 继续
endfunction
```

### 1.2 改进错误诊断

**问题**: `vide-fs` 错误消息缺乏上下文

**当前代码** (`lib/vide-fs.c:213-217`):
```c
if (result < 0)
    fail("filesystem operation failed");
```

**修复方案**:
```c
// lib/vide-fs.c 新增函数
static void fail_with_context(const char *operation, const char *path, const char *detail)
{
    if (detail && *detail)
        fprintf(stderr, "%s: %s: %s: %s\n", operation, path, detail, strerror(errno));
    else
        fprintf(stderr, "%s: %s: %s\n", operation, path, strerror(errno));
    exit(1);
}

// 使用示例
if (result < 0) {
    if (!strcmp(argv[2], "create-file"))
        fail_with_context("create-file", argv[3], "cannot create");
    else if (!strcmp(argv[2], "delete"))
        fail_with_context("delete", argv[3], "cannot remove");
    // ...
}
```

**文件**: `lib/vide-fs.c:19-23`, `lib/vide-fs.c:163-218`

### 1.3 处理路径截断

**问题**: 长路径被静默丢弃

**当前代码** (`lib/vide-watch.c:216-218`, `lib/vide-watch.c:258-260`):
```c
if (snprintf(path, sizeof(path), "%s/%s", path, item->d_name) >= (int)sizeof(path))
    continue;  // 静默跳过
```

**修复方案**:
```c
int len = snprintf(child, sizeof(child), "%s/%s", path, item->d_name);
if (len >= (int)sizeof(child)) {
    emit_error(path, "path component too long, skipping");
    continue;
}
```

**文件**: `lib/vide-watch.c:216-218`, `lib/vide-watch.c:258-263`

---

## 阶段 2：性能优化（1 周）

### 2.1 优化监控描述符查找

**问题**: O(n) 线性扫描在大型项目中成为瓶颈

**当前代码** (`lib/vide-watch.c:68-75`):
```c
static ssize_t find_entry(int wd)
{
    size_t i;
    for (i = 0; i < entry_count; ++i)
        if (entries[i].wd == wd)
            return (ssize_t)i;
    return -1;
}
```

**修复方案**: 使用哈希表
```c
#include <search.h>

struct wd_hashmap {
    int wd;
    size_t index;
};

static struct hsearch_data wd_table;
static int wd_table_initialized = 0;

static void init_wd_table(void)
{
    memset(&wd_table, 0, sizeof(wd_table));
    if (!hcreate_r(1024, &wd_table))
        die("cannot initialize watch descriptor table");
    wd_table_initialized = 1;
}

static ssize_t find_entry(int wd)
{
    ENTRY search, *found;
    char key[32];
    
    snprintf(key, sizeof(key), "%d", wd);
    search.key = key;
    search.data = NULL;
    
    if (!hsearch_r(search, FIND, &found, &wd_table))
        return -1;
    
    return (ssize_t)(uintptr_t)found->data;
}

static void remember_watch(int wd, const char *path)
{
    // ... 原有逻辑 ...
    
    // 添加到哈希表
    ENTRY entry;
    char *key = malloc(32);
    snprintf(key, 32, "%d", wd);
    entry.key = key;
    entry.data = (void *)(uintptr_t)(entry_count - 1);
    
    ENTRY *result;
    if (!hsearch_r(entry, ENTER, &result, &wd_table)) {
        // 表满，扩展
        hdestroy_r(&wd_table);
        init_wd_table();  // 重新创建更大的表
        // 重新插入所有条目
    }
}
```

**文件**: 创建新文件 `lib/vide-watch-hashmap.c`，在 `lib/vide-watch.c` 中集成

**性能影响**: 在有 10,000+ 目录的项目中从 O(n) 降至 O(1)

### 2.2 优化目录读取

**问题**: 对同一目录进行两次 glob 调用

**当前代码** (`src/vide.vim:333-344`):
```vim
function! s:Children(path) abort
  let l:entries = globpath(a:path, '*', 0, 1) + globpath(a:path, '.*', 0, 1)
  " ...
endfunction
```

**修复方案**: 使用单次 `readdir()`
```vim
function! s:Children(path) abort
  let l:result = []
  try
    let l:entries = readdirex(a:path)
    for l:entry in l:entries
      let l:name = l:entry.name
      if l:name ==# '.' || l:name ==# '..'
        continue
      endif
      let l:normalized = s:NormalizePath(a:path . '/' . l:name)
      if !s:IsTransient(l:normalized)
        call add(l:result, l:normalized)
      endif
    endfor
  catch /^Vim\%((\a\+)\)\=:E/
    return []
  endtry
  return sort(l:result, function('s:ComparePaths'))
endfunction
```

**文件**: `src/vide.vim:333-344`

---

## 阶段 3：代码重构（2-3 周）

### 3.1 模块化 Vim 运行时

**当前结构**: 单个 1,150 行文件

**目标结构**:
```
src/
  vide.vim              (150 行) - 主入口和自动命令
  vide/
    core.vim            (100 行) - 核心变量和初始化
    tree.vim            (300 行) - 树渲染和导航
    watch.vim           (250 行) - 文件监控集成
    fs.vim              (150 行) - 文件系统操作
    settings.vim        (150 行) - 设置管理
    ui.vim              (200 行) - UI 组件（弹窗、启动屏）
```

**实现计划**:

1. **创建模块基础设施** (`src/vide.vim`):
```vim
" vide.vim - 主入口
if exists('g:loaded_vide_runtime')
  finish
endif
let g:loaded_vide_runtime = 1

let s:script_dir = expand('<sfile>:p:h')

" 加载模块
execute 'source ' . fnameescape(s:script_dir . '/vide/core.vim')
execute 'source ' . fnameescape(s:script_dir . '/vide/tree.vim')
execute 'source ' . fnameescape(s:script_dir . '/vide/watch.vim')
execute 'source ' . fnameescape(s:script_dir . '/vide/fs.vim')
execute 'source ' . fnameescape(s:script_dir . '/vide/settings.vim')
execute 'source ' . fnameescape(s:script_dir . '/vide/ui.vim')

" 自动命令和入口点
call vide#core#LoadSettings()
augroup vide_runtime
  autocmd!
  autocmd VimEnter * call vide#core#Start()
  autocmd VimResized * call vide#ui#ResizeSidebar()
  " ...
augroup END
```

2. **提取模块** - 按功能分组函数：

**`src/vide/core.vim`**: 全局状态、初始化、路径工具
**`src/vide/tree.vim`**: 树渲染、节点操作、激活/折叠
**`src/vide/watch.vim`**: 监控器生命周期、事件处理、快照管理
**`src/vide/fs.vim`**: 文件系统包装器、安全路径验证
**`src/vide/settings.vim`**: 设置加载/保存/验证、弹窗
**`src/vide/ui.vim`**: 高亮、启动屏、中断处理、窗口样式

3. **使用自动加载函数** (`autoload/vide.vim`):
```vim
" 公共 API 使用 vide#function 命名
function! vide#tree#render() abort
  " ...
endfunction

" 内部函数使用 s: 前缀保持私有
function! s:add_node(path, depth, lines, nodes) abort
  " ...
endfunction
```

**迁移策略**:
- 阶段 1: 创建模块文件，复制函数（保持 `src/vide.vim` 工作）
- 阶段 2: 更新函数调用为 `vide#module#function()`
- 阶段 3: 从 `src/vide.vim` 删除原始函数
- 阶段 4: 运行完整测试套件验证

### 3.2 改进测试覆盖

**当前覆盖**: ~60% - 基本操作、事件驱动更新、路径验证

**新测试**:

**`tests/test_errors.vim`** - 错误恢复:
```vim
" 测试监控器崩溃恢复
call system('pkill -9 vide-watch')
sleep 1
call assert_equal('OFF', g:vide_watch_backend)
call assert_match('ERROR', g:vide_notice)

" 测试权限被拒绝
call mkdir(s:root . '/forbidden')
call system('chmod 000 ' . shellescape(s:root . '/forbidden'))
call writefile(['test'], s:root . '/allowed.txt')
sleep 500m
call assert_equal(s:root . '/allowed.txt', expand('%:p'))

" 测试磁盘满（困难 - 需要模拟）
```

**`tests/test_large_files.vim`** - 边界条件:
```vim
" 测试超过 content_limit 的文件
let s:huge = repeat(['line'], 100000)
call writefile(s:huge, s:root . '/huge.txt')
sleep 500m
call assert_equal(s:root . '/huge.txt', expand('%:p'))
call assert_false(has_key(s:watch.contents, s:root . '/huge.txt'))

" 测试快照驱逐
for s:i in range(0, 100)
  call writefile(repeat(['data'], 1000), s:root . '/file' . s:i . '.txt')
  sleep 50m
endfor
call assert_true(len(keys(s:watch.contents)) < 100)
```

**`tests/test_concurrent.vim`** - 并发:
```vim
" 测试 Vim 打开文件的外部修改
edit test.txt
call setline(1, 'vim content')
call writefile(['external content'], s:root . '/test.txt')
sleep 500m
call assert_equal('vim content', getline(1))  " Vim 缓冲区不变
call assert_true(&modified)  " 标记为外部更改
```

**文件**: 创建 `tests/test_errors.vim`, `tests/test_large_files.vim`, `tests/test_concurrent.vim`

---

## 阶段 4：跨平台支持（3-4 周）

### 4.1 抽象监控器接口

**目标**: 支持 Linux (inotify)、macOS/BSD (kqueue)、Windows (ReadDirectoryChangesW)

**新文件结构**:
```
lib/
  vide-watch.h          - 公共接口
  vide-watch-main.c     - 主循环和协议
  vide-watch-linux.c    - inotify 实现
  vide-watch-bsd.c      - kqueue 实现
  vide-watch-windows.c  - ReadDirectoryChanges 实现
```

**`lib/vide-watch.h`**:
```c
#ifndef VIDE_WATCH_H
#define VIDE_WATCH_H

struct watch_backend {
    int (*init)(const char *root);
    int (*add_tree)(const char *path, int announce_files);
    int (*read_events)(void (*handler)(const char *type, const char *path));
    void (*cleanup)(void);
};

extern const struct watch_backend *vide_watch_backend;

#endif
```

**`lib/vide-watch-linux.c`** - 当前 inotify 实现移至此处

**`lib/vide-watch-bsd.c`** - 新 kqueue 实现:
```c
#include <sys/event.h>

static int kq = -1;
static struct kevent *events;

static int init_kqueue(const char *root)
{
    kq = kqueue();
    if (kq < 0)
        return -1;
    // 设置监控
    return 0;
}

static int add_tree_kqueue(const char *path, int announce_files)
{
    int fd = open(path, O_RDONLY);
    if (fd < 0)
        return -1;
    
    struct kevent kev;
    EV_SET(&kev, fd, EVFILT_VNODE, EV_ADD | EV_CLEAR,
           NOTE_WRITE | NOTE_DELETE | NOTE_RENAME, 0, NULL);
    
    if (kevent(kq, &kev, 1, NULL, 0, NULL) < 0) {
        close(fd);
        return -1;
    }
    
    // 递归添加子目录
    return 0;
}

const struct watch_backend vide_watch_kqueue = {
    .init = init_kqueue,
    .add_tree = add_tree_kqueue,
    .read_events = read_events_kqueue,
    .cleanup = cleanup_kqueue
};
```

**`Makefile`** 条件编译:
```makefile
UNAME := $(shell uname -s)

ifeq ($(UNAME),Linux)
    WATCH_SRC := lib/vide-watch-main.c lib/vide-watch-linux.c
endif
ifeq ($(UNAME),Darwin)
    WATCH_SRC := lib/vide-watch-main.c lib/vide-watch-bsd.c
endif
ifeq ($(UNAME),FreeBSD)
    WATCH_SRC := lib/vide-watch-main.c lib/vide-watch-bsd.c
endif

$(WATCHER): $(WATCH_SRC) lib/vide-watch.h
	$(CC) $(CFLAGS) -std=c11 -o $@ $(WATCH_SRC)
```

### 4.2 Windows 支持

**挑战**: Windows 无 `openat`/`renameat`，路径语义不同

**方案**:
1. **监控器**: 使用 `ReadDirectoryChangesW` + `FILE_NOTIFY_INFORMATION`
2. **文件系统助手**: 使用 Windows API (`CreateFileW`, `MoveFileExW`)
3. **启动器**: 提供 `bin/vide.bat` 批处理脚本

**`lib/vide-fs-windows.c`** (骨架):
```c
#include <windows.h>

static HANDLE open_root(const wchar_t *path)
{
    return CreateFileW(path, GENERIC_READ, 
                      FILE_SHARE_READ | FILE_SHARE_WRITE,
                      NULL, OPEN_EXISTING,
                      FILE_FLAG_BACKUP_SEMANTICS, NULL);
}

static int rename_no_replace(const wchar_t *old_path, const wchar_t *new_path)
{
    return MoveFileExW(old_path, new_path, 0) ? 0 : -1;
}

// ... Windows 特定实现
```

**估计工作量**: 2-3 周（需要 Windows 开发环境）

---

## 阶段 5：高级功能（未来）

### 5.1 可配置忽略模式

**功能**: `.videignore` 文件排除 `node_modules`、`target`、`.git` 等

**实现**:
```vim
" src/vide/ignore.vim
function! vide#ignore#load_patterns() abort
  let l:ignore_file = s:root . '/.videignore'
  if !filereadable(l:ignore_file)
    return ['^\.git/', 'node_modules/', '__pycache__/']  " 默认
  endif
  return map(readfile(l:ignore_file), 'v:val')
endfunction

function! vide#ignore#should_ignore(path) abort
  for l:pattern in s:ignore_patterns
    if a:path =~# l:pattern
      return 1
    endif
  endfor
  return 0
endfunction
```

**集成**: 在 `s:Children()` 和 `add_tree()` 中检查

### 5.2 增量快照

**目标**: 仅存储差异而非完整内容，节省内存

**数据结构**:
```vim
let s:watch = {
  \ 'baseline': {},        " 原始内容
  \ 'diffs': {},          " 差异列表
  \ 'current_hash': {}    " 当前哈希
\ }
```

**差异格式**:
```vim
let l:diff = [
  \ {'type': 'change', 'line': 5, 'before': 'old', 'after': 'new'},
  \ {'type': 'insert', 'line': 10, 'text': 'added line'},
  \ {'type': 'delete', 'line': 15}
\ ]
```

**预期收益**: 对于大文件的小改动，内存减少 80-90%

### 5.3 远程文件系统支持

**功能**: 通过 SSH 监控远程项目

**方案**:
```
本地 Vim <--> vide-ssh-proxy <--> SSH <--> 远程 vide-watch
```

**`bin/vide-ssh-proxy`**:
```bash
#!/bin/bash
ssh "$REMOTE_HOST" "cd $REMOTE_DIR && vide-watch ." | \
  while IFS= read -r event; do
    # 转换远程路径为本地 FUSE 挂载路径
    echo "$event" | sed "s|$REMOTE_DIR|$LOCAL_MOUNT|g"
  done
```

---

## 实施时间表

| 阶段 | 持续时间 | 优先级 | 依赖 |
|------|---------|--------|------|
| **阶段 1: 安全修复** | 1-2 周 | 🔴 关键 | 无 |
| **阶段 2: 性能优化** | 1 周 | 🟡 高 | 无 |
| **阶段 3: 代码重构** | 2-3 周 | 🟡 高 | 阶段 1 |
| **阶段 4: 跨平台** | 3-4 周 | 🟢 中 | 阶段 3 |
| **阶段 5: 高级功能** | 按需 | 🔵 低 | 阶段 4 |

**总计**: 7-10 周的全职开发

---

## 测试策略

### 每个阶段的验证

**阶段 1 - 安全**:
```bash
# 运行现有测试
make test

# 手动安全测试
bash tests/manual_security_tests.sh
```

**阶段 2 - 性能**:
```bash
# 基准测试
bash tests/benchmark.sh

# 验证大型项目（10,000+ 文件）
git clone https://github.com/torvalds/linux /tmp/linux
VIDE_VIM=vim bin/vide /tmp/linux
```

**阶段 3 - 重构**:
```bash
# 回归测试
make test

# 模块加载测试
vim -Nu src/vide.vim -c 'echo exists("*vide#tree#render")' -c quit
```

**阶段 4 - 跨平台**:
```bash
# Linux
make test

# macOS (需要 macOS 机器)
make test

# Windows (需要 Windows + MinGW)
mingw32-make test
```

### 持续集成

**`.github/workflows/ci.yml`**:
```yaml
name: CI

on: [push, pull_request]

jobs:
  test-linux:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Build
        run: make all
      - name: Test
        run: make test
  
  test-macos:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v3
      - name: Build
        run: make all
      - name: Test
        run: make test
```

---

## 发布里程碑

### v0.2.0 - 安全强化版
- ✅ 修复 TOCTOU 竞态条件
- ✅ 改进错误诊断
- ✅ 路径截断处理
- ✅ 扩展测试覆盖

### v0.3.0 - 性能优化版
- ✅ 哈希表监控查找
- ✅ 优化目录读取
- ✅ 大型项目基准测试

### v0.4.0 - 重构版
- ✅ 模块化代码库
- ✅ 自动加载函数
- ✅ 全面测试套件

### v0.5.0 - 跨平台版
- ✅ macOS/BSD 支持 (kqueue)
- ✅ Windows 支持（可选）
- ✅ 统一构建系统

### v1.0.0 - 生产就绪版
- ✅ 所有平台稳定
- ✅ 完整文档
- ✅ 性能优化
- ✅ 安全审计通过

---

## 资源需求

### 开发人员
- **1 位高级 C 开发者**（系统编程、inotify/kqueue）
- **1 位 Vim 专家**（Vimscript、插件架构）
- **可选: 1 位 Windows 开发者**（阶段 4）

### 基础设施
- **Linux 开发环境**（Ubuntu/Fedora）
- **macOS 测试机**（阶段 4）
- **Windows 测试环境**（阶段 4，可选）
- **CI/CD 管道**（GitHub Actions）

### 测试资源
- **大型代码库**用于性能测试（Linux 内核、Chromium）
- **各种文件系统**（ext4、btrfs、APFS、NTFS）
- **网络存储**用于远程测试（NFS、CIFS）

---

## 风险缓解

| 风险 | 影响 | 概率 | 缓解策略 |
|------|------|------|---------|
| 重构引入回归 | 高 | 中 | 全面测试套件，逐步迁移 |
| 跨平台 API 差异 | 中 | 高 | 抽象层，早期原型 |
| 性能优化破坏正确性 | 高 | 低 | 基准测试 + 正确性测试 |
| Windows 端口需要重写 | 中 | 中 | 考虑仅限 Unix 的 v1.0 |

---

## 成功指标

### 代码质量
- [ ] 测试覆盖率 > 80%
- [ ] 无已知安全漏洞
- [ ] 所有模块 < 500 行
- [ ] 静态分析干净（`clang-tidy`, `vint`）

### 性能
- [ ] 10,000 文件项目中 < 100ms 事件延迟
- [ ] 监控器内存 < 50MB（100,000 监控）
- [ ] 快照预算遵守 ±5%

### 可用性
- [ ] 在 3 个平台上构建无错误
- [ ] 所有核心功能有文档
- [ ] 新用户在 5 分钟内开始使用

---

## 下一步

1. **评审此计划**（与维护者/利益相关者）
2. **建立开发环境**（Linux + macOS 访问权限）
3. **创建功能分支**: `git checkout -b improve/phase-1-security`
4. **开始阶段 1**: 修复 TOCTOU 竞态条件
5. **设置 CI**: GitHub Actions 自动化测试

---

*此计划基于 2026-08-08 的代码审查。随着发现新问题，根据需要更新。*
