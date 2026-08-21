# Changelog

## 1.0.0 (2026-08-21)

各プロジェクトの `Assets/you5248/Shaders/` に手動コピーで散在していた dhk Standard を
VPM パッケージとして切り出した。

- 内容は washitu プロジェクトの最新版（2026-07-30）を採用。
  shader test 側にあったコピーは 2026-07-15 版で、MonoSH 対応が入っていない古いものだった
- Quest 向け `you5248/Quest/dhk Standard` を同梱
- GUID は従来どおり固定（`dhkStandard` = `0f1e2d3c…` / `dhkStandardQuest` = `42d3ca77…`）
