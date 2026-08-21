# Changelog

## 1.1.0 (2026-08-21)

バグ修正と専用 ShaderGUI の追加。マギシステムの三賢者合議で設計・レビューした。

### 修正したバグ

- **各テクスチャの Tiling/Offset が効かなかった**（報告された不具合）。
  全マップが `uv_MainTex`、すなわち `_MainTex` の ST でサンプルされていた。
  生 UV を1本だけ渡し、`TRANSFORM_TEX` で各マップの `_ST` を個別に適用するように変更。
  PC 版・Quest 版の両方。
- **Quest 版で Metallic マップが死んでいた**。`metallic = mg.r * _Metallic` となっており、
  `_Metallic` の既定値 0 のせいでマップを ON にしても金属にならなかった。PC 版と同じ `mg.r` に統一。
- **Alpha Cutout を ON にしても RenderType / Render Queue が Opaque・Geometry のままだった**。
  タグはキーワードで切り替わらないため、ShaderGUI が**トグルを切り替えた瞬間**と
  **シェーダーを載せ替えた時**に設定する。
  読み込みのたびには書かない（Render Queue 欄の手入力を潰さないため）。
  そのため**既に壊れている既存マテリアルは自動では直らない**。
  該当するマテリアルを選ぶとインスペクタ上部に警告と「Render Queue を AlphaTest に直す」
  ボタンが出るので、それを押すと直る。
- **Emission を ON にしてもベイクに寄与しないことがあった**。
  ShaderGUI が `globalIlluminationFlags` の `EmissiveIsBlack` を同期する。
  寄与先（Baked / Realtime / None）は Emission 欄の Global Illumination で選べる。
  **`None` を選んだ場合はそのまま保たれる**（読み込みのたびに Baked へ戻したりはしない）。
  Baked を既定として与えるのは、トグルを OFF→ON にした瞬間と、シェーダーを載せ替えた時だけ。
- MonoSH のベイクスペキュラで、支配方向がゼロ長のとき `normalize()` が NaN を返していた。
  長さで打ち切り、`roughness` にも下限を設けた。

### 変更

- 手書きの LOD Cross-Fade ディザ（`screenPos` + `UnityApplyDitherCrossFade`）を廃止し、
  `#pragma surface ... dithercrossfade` に置換。補間子が1本減り、影パスにも標準経路で適用される。
- Quest 版で `o.Normal` を無条件に書くのをやめた（ノーマルマップ未使用時の無駄をなくす）。
- 専用 ShaderGUI を追加（`Editor/DhkStandardGUI.cs`）。詳細は README を参照。

### ⚠ 移行時の注意

**これまで各マップの Tiling/Offset は無視されていたので、既定以外の値が入ったまま
放置されているマテリアルは、今回の修正で見た目が変わる。**
`_MainTex` の ST で全マップを動かしていた回避策も効かなくなる。
既存マテリアルは各マップの ST を確認すること
（本プロジェクトの既存4マテリアルは全て等倍・オフセット0で、影響が無いことを確認済み）。

Quest 版で Metallic マップを ON にしていたマテリアルは、今回初めて金属として扱われる。
マップが白いままだと拡散が消えて黒く見えるので、マップの内容を確認すること。

## 1.0.0 (2026-08-21)

各プロジェクトの `Assets/you5248/Shaders/` に手動コピーで散在していた dhk Standard を
VPM パッケージとして切り出した。

- 内容は washitu プロジェクトの最新版（2026-07-30）を採用。
  shader test 側にあったコピーは 2026-07-15 版で、MonoSH 対応が入っていない古いものだった
- Quest 向け `you5248/Quest/dhk Standard` を同梱
- GUID は従来どおり固定（`dhkStandard` = `0f1e2d3c…` / `dhkStandardQuest` = `42d3ca77…`）
