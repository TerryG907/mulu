Mulu 给 PDF 加上可以点击的多级目录，原文件的字节一个都不改。这里是图形界面 Mulu.app 的早期版本。

**安装**：下载 `@ZIP@`，解压，双击 Mulu.app（可以先拖进「应用程序」）。

- 只支持 Apple 芯片（arm64），需要 macOS 14 或更新。开发和测试只在一台 Apple M5 Pro、macOS 26.6.2 上做过。
- zip 里只有图形界面。命令行工具 `mulu` 要从源码构建，见 [README](@REPO_URL@/blob/@TAG@/README.md)。
- 用法、快捷键和已知限制见 [docs/GUI.md](@REPO_URL@/blob/@TAG@/docs/GUI.md)。

**第一次打开会被 macOS 拦住。** Mulu.app 只有 ad-hoc 签名，没有 Developer ID，也没有 Apple 公证。

- macOS 14：在 Finder 里右键点 Mulu.app ▸ 打开 ▸ 再点「打开」。
- macOS 15 及以后：先双击一次（会被拦），再到「系统设置 ▸ 隐私与安全性」，点「仍要打开」。

上面这条「下载后被拦、再放行」的路径我们没有在第二台 Mac 上实测过；这个 zip 在 GitHub 的构建机上编译，发布前没有在构建机上启动过。打不开的话，请到 [Issues](@REPO_URL@/issues) 说一声。

这个 zip 由 GitHub Actions 从标签 `@TAG@` 的源码构建。下载后可以用 `shasum -a 256 @ZIP@` 核对 SHA-256：

```
@SHA256@
```

---

Mulu adds a clickable multi-level outline (bookmarks) to a PDF without changing any original byte. This is an early version of the Mac app, Mulu.app.

**Install**: download `@ZIP@`, unzip it and double-click Mulu.app (move it to Applications first if you like).

- Apple silicon only (arm64), macOS 14 or later. Developed and tested only on one Apple M5 Pro with macOS 26.6.2.
- The zip contains the app only. The command-line tool `mulu` is built from source, see the [README](@REPO_URL@/blob/@TAG@/README.md#english).
- Usage, shortcuts and known limits: [docs/GUI.md](@REPO_URL@/blob/@TAG@/docs/GUI.md) (in Chinese).

**macOS blocks the first launch.** Mulu.app is ad-hoc signed: no Developer ID, not notarized by Apple.

- macOS 14: in Finder, right-click Mulu.app ▸ Open ▸ Open.
- macOS 15 and later: double-click it once (it is blocked), then open System Settings ▸ Privacy & Security and click "Open Anyway".

We have not tested this blocked-download path on a second Mac, and this zip was compiled on a GitHub runner and not launched there before publishing. If it does not open, please tell us in [Issues](@REPO_URL@/issues).

The zip is built by GitHub Actions from the source at tag `@TAG@`. To check the download, compare `shasum -a 256 @ZIP@` with:

```
@SHA256@
```
