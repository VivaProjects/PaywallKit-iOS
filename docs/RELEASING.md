# 独立版本与发布

本目录为独立 Git 仓库，版本来源是 `VERSION`，变更记录为 `CHANGELOG.md`。版本、提交和标签只属于本仓库，不要求其他项目同步升级。

```sh
python3 tools/version.py show
python3 tools/version.py check
python3 tools/version.py bump patch --note "本次修复说明"
```

支持 `major`、`minor`、`patch`，分别用于不兼容变更、兼容功能和修复。Flutter 升版会同步自身 iOS 插件 podspec。SDK 版本不替代桥协议版本或页面 revision。

运行 tools/check_package.py、Swift Package 清单解析与 iOS 编译，并在宿主验证受影响流程。

确认检查通过、审阅并提交当前仓库变更后执行：

```sh
python3 tools/version.py tag
```

该命令要求当前目录确实是 Git 根目录、工作区干净，版本与变更记录一致，且同名标签不存在。它创建标准 `X.Y.Z` 的本地附注标签，不自动提交或推送，也不代替编译测试。初始目录拆分本身不自动创建发布标签。

将本仓库配置为真实远端后，可自行推送提交和相应标签。例如当前版本为 0.1.0 时：

```sh
git remote add origin <THIS_REPOSITORY_GIT_URL>
git push -u origin HEAD
git push origin 0.1.0
```

占位 URL 必须替换；已配置 origin 时不要重复添加。两个 SDK 根目录可直接作为 Git 依赖发布，无需再次导出或复制到父仓库。iOS 标准版本标签可供 SwiftPM 解析；Flutter 使用 Git ref 固定版本，当前未启用 pub.dev 发布。没有新增远端，也没有执行推送。
