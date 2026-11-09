# anti_fraud_ads 构建仓库

推送到 GitHub 后，Actions 会自动编译「开屏广告自动跳过」的 Zygisk 库，并打包成可直接刷入的完整模块。

## 目录
- `module/`：模块本体（脚本、设置页、AdGuard Home），和不带开屏跳过的安装包内容完全一样
- `zygisk/src/main.cpp`：Zygisk 库。应用启动时向 companion 询问是否在名单里，不在就立即卸载自己
- `zygisk/java/afa/skip/Main.java`：注入到选中应用里的代码，负责找「跳过」并点击
- `zygisk/build.sh`：编译与打包脚本（需要 Android SDK、NDK、JDK 17，GitHub 的 ubuntu-latest 都自带）
- `.github/workflows/build.yml`：每次推送自动构建

## 使用
1. 新建一个仓库（建议私有），把本目录全部内容推上去（注意 `.github` 是隐藏目录，别漏了）
2. 打开仓库的 Actions 页，等「构建模块」跑完（约 2~3 分钟）
3. 在这次运行的页面底部下载 `anti_fraud_ads`，解压一次得到 `anti_fraud_ads_v7.9.zip`，直接在管理器里刷入

## 排查
- 构建失败：把 Actions 日志里的报错发出来
- 刷入后不生效：设置页「开屏」→「最近跳过记录」，或在终端执行 `logcat -s AFA-Skip`
