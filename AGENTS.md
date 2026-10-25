# AGENTS.md

给在这个仓库里干活的 AI。人看的在 [README.md](README.md)，技术细节在 [TECHNICAL.md](TECHNICAL.md)，素材权利在 [NOTICE.md](NOTICE.md)。

## 构建与验证

- `./build.sh` 编译并跑 `--self-test`，最后一行必须是 `PASS`。没 PASS 就是没改完。
- `./install.sh --build` 装进 /Applications 并启动；`./build.sh --package` 产出 dist/ 下的 zip、dmg、sha256。
- 只支持 Apple Silicon + macOS 14，构建脚本里写死 arm64，不要为 Intel 改。
- 诊断入口：`--self-test`、`--dump-state`、`--trace`、`--bridge-test`

## 不能破的约束

- `Sources/Bridge.swift` 在 SunPet / ShaolanPet / FengGe-Desktop-Pet 三个仓库里必须逐字节相同。改一处要三处同步，验法：`md5 -q Sources/Bridge.swift` 三份一致。
- `LICENSE` 只放标准 MIT 全文。素材权利写在 `NOTICE.md`，第三方代码许可放 `licenses/`。往 LICENSE 末尾追加例外会让 GitHub 判成 `NOASSERTION`，按 MIT 筛选就搜不到；验法 `gh api repos/Ganzhe2028/FengGe-Desktop-Pet --jq .license.spdx_id` 要返回 `MIT`。
- README 是给刷到视频的普通人看的落地页，只放四块：四张脸互链、装三步、一句自己的效果、立场。技术长文一律进 TECHNICAL.md。
- README 顶部四张脸是四个独立 App 的互链，不是同一个 App 的皮肤。这句说明不能删。
- 二进制不进仓库，安装包走 Releases。

## 发布

打 `v*` tag 会触发 `.github/workflows/release.yml` 自动构建并上传 `GoodThingPet-<版本>.dmg/.zip/.sha256`。三个仓库的资产命名保持一致，README 写死「下载最新的 `.dmg`」。

## 联动

三个桌宠靠 `DistributedNotificationCenter` 互相接话，`hop` / `root` 两个字段防环。加角色先读 TECHNICAL.md 的《加第四个人》，同时确认 peers、hop 上限、root 条件三处。`--self-test` 不覆盖联动，别靠 PASS 宣布通了。第四个 [JellyPet](https://github.com/aurelius358/JellyPet) 是别人做的形状挂件，没有语音，不在这套协议里。

## 这个仓库

- app：`好事桌宠.app`，bundle id `local.goodthing.desktop-pet`
- 四步链位置：峰哥，只在薄肌起的链里接太对了
- peers：`[.sunpet]`
