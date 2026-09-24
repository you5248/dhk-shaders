# dhk Shaders

Unityビルトイン（BiRP / Forward）向けの**軽量Standard互換シェーダー**。

| シェーダー | 用途 |
|---|---|
| `you5248/dhk Standard (Bicubic Lightmap)` | PC向け本命 |
| `you5248/Quest/dhk Standard` | Quest（Android）向け軽量版 |

## 何が違うのか

- **ライティングは Unity 標準の Standard と同じ**（Unity の BRDF / 全ライトパス / 影 / メタパス）。
  既定値では Standard と同じ結果になる
- **バイキュービック 4 タップのライトマップサンプリング** — 低解像度ベイクのブロック段差をならす。
  追加コストは「ライトマップがある時に参照が 1 → 4 タップに増える」だけ
- **MonoSH**（指向性ライトマップ）対応 — ライトマップからスペキュラ／ノーマル反応を出す
- **LOD Cross-Fade（ディザ）対応** — LODGroup の Fade Mode = Cross Fade で切替のポップを抑える
- **VRC Light Volumes** 対応（拡散。鏡面と影マスクは任意で ON）
- 追加機能（ディテールマップ / スペキュラ強調 / GSAA / リムライト / 両面描画）は既定で OFF。
  OFF の機能は分岐の判定などわずかな固定費だけで、Mochie / Filamented より軽い

## Standard からの差し替え

プロパティ名を Unity Standard と一致させてあるので、
Standard マテリアルのシェーダーをこれに変えるだけで色・metallic・smoothness 等はそのまま残る。

マップ系は `[Toggle]` で明示的に ON にする方式（`_BumpMap` にテクスチャを入れるだけでは効かない）。
ただし専用の ShaderGUI が入っているので、Standard から乗り換えたときは
**割り当て済みのマップからトグルを自動で立てる**。手で入れ直す必要はない。

## インスペクタ（ShaderGUI）

`you5248.DhkShadersEditor.DhkStandardGUI` が PC 版・Quest 版の両方を描画する。

- 機能トグルが OFF の項目は畳んで表示しない
- **Tiling/Offset は実際に効くテクスチャにだけ出す**（各マップが自分の ST を持つ）
- Metallic/Smoothness マップが ON のときは、上書きされる `Metallic` / `Smoothness` を隠す
- Quest 版で読まれないプロパティ（`Smoothness` 等、PC からのコピー互換で残しているもの）は出さない
- Emission の ON/OFF に応じて `globalIlluminationFlags` を同期する（未設定なら Baked を既定にする）
- Alpha Cutout を切り替えたときだけ `RenderType` タグと Render Queue を書き換える
  （読み込みのたびに書くと、Render Queue 欄の手入力を潰してしまうため）

## VRC Light Volumes

`red.sim.lightvolumes` が入っているプロジェクトでは、インスペクタに
「VRC Light Volumes」欄が出る（入っていなければ出ない）。

- ライトマップあり → 加算ボリュームだけを足す（ベイクとの二重計上を避ける）
- ライトマップなし → Unity の SH を置き換える
- `サンプル位置を法線方向へずらす` は漏光対策。既定 0
- **LV スペキュラ**（既定 0 = OFF）: LV の L1 から鏡面を作る。`LightVolumeSpecular` は f0 適用済みの
  最終反射色なので、GI の鏡面には入れず BRDF の後で加算している（GI に入れるとフレネルが二重に掛かる）
- **影マスク**（LV 3.x のみ）: ベイク済みの通常ボリュームにリアルタイム Directional の影を掛け、
  ベイクしたような濃い影を出す。加算ボリュームと Point Light Volume には掛けない

LV のバージョンで経路が変わる。起動時に自動で判定し、`dhkPackages.cginc` に書き出す。

| LV のバージョン | ライトマップの無い面の評価 |
|---|---|
| 未導入 | Unity の SH のみ |
| 2.x | 公開 API の `LightVolumeSH`（1.4.1 と同じ）。影マスクは無効 |
| 3.x | 通常 / 加算 / Point Light Volume を分けて評価。影マスクと Point Light Volume の当たり方（`_LVPointLightShading`）が使える |

`_LVPointLightShading` は 0〜3（既定 0）。0 は面の向きを見ない（1.4.x と同じ）。
3 は LV 3.x 自身の既定で、光源の反対を向いた面には当たらない。
LV 3.x の判定は、使う内部関数が実在するかで行う（内部関数が無い版は 2.x と同じ扱い）。

Quest 版は非対応。

> Light Volumes が入っていないプロジェクトでも壊れない。
> 自動生成の `Runtime/Shaders/dhkPackages.cginc` に define がある時だけ include する仕組み。
> 検出をやり直したいときは `Tools > you5248 > dhk Shaders > 連携パッケージを再検出`。

## パックマップ（Metallic / Occlusion / Smoothness を1枚に詰めたもの）

`_MetallicGlossMap` はチャンネル割り当てを選べる。インスペクタの「チャンネル構成」から:

| プリセット | 割り当て |
|---|---|
| Unity Standard | Metallic=R, Smoothness=A |
| MOS / MAS | Metallic=R, Occlusion=G, Smoothness=B |
| ORM (glTF) | Occlusion=R, **Roughness**=G, Metallic=B |
| HDRP Mask | Metallic=R, Occlusion=G, Smoothness=A |
| Custom | Metallic / Smoothness / Occlusion をそれぞれ R/G/B/A/使わない から選ぶ |

ORM のように Smoothness ではなく **Roughness** で入っているマップ用に、
「Roughness として解釈する (1 - 値)」トグルがある。

パックマップから AO を取る場合、別の Occlusion マップは読まれない（インスペクタでも畳まれる）。

> ⚠ マスク系のテクスチャは **sRGB (Color Texture) を OFF** にすること。
> ON のままだと値が歪む。インスペクタが警告を出す（Importer 設定を勝手に変えることはしない）。

既定は Unity Standard 互換なので、**既存マテリアルの見た目は変わらない**。

## テクスチャごとの Tiling / Offset

`_MainTex` / `_MetallicGlossMap` / `_BumpMap` / `_OcclusionMap` / `_EmissionMap` と
ディテールの各マップ（Albedo / Normal / Metallic・Smoothness / Occlusion / Mask）は
**それぞれ独立した Tiling/Offset を持つ**。生の UV を1本だけ渡し、
サーフェス側で各 `_ST` を適用しているため、補間子はバリアントによらず一定。

> Unity Standard はディテールの全マップが Detail Albedo の Tiling/Offset を共有し、
> Detail Mask はメインの Tiling/Offset で読む（`_UVSec` で UV2 も選べる）。
> このシェーダーは UV1 のみで、各マップの Tiling/Offset を個別に使う。
> また、D3D11 のサンプラー数の上限に収めるため、ディテールの各マップは Detail Albedo のサンプラーを共有する
> （Wrap / Filter は Detail Albedo のテクスチャの設定に従う）。
> Standard から乗り換えた場合は、ディテールの Tiling/Offset を確認すること。

## 追加機能

どれも既定で OFF（または無効値）。OFF のときの見た目は 1.4.x と同じで、コストもほぼ変わらない。

| 機能 | プロパティ | 内容 |
|---|---|---|
| ディテールマップ | `_UseDetail` ほか | Detail Albedo（MulX2 / Multiply / Add / Overlay / Replace）、Detail Normal、Detail Metallic(R)・Smoothness(A) の乗算、Detail Occlusion(G)、Detail Mask(A) |
| スペキュラ強調 | `_SpecBoost`（1〜8） | F0 だけを持ち上げる。拡散は変えないので明るさの土台はそのまま（LV スペキュラには掛からない） |
| GSAA | `_UseGSAA` | 法線の画面内の変化量で粗さを底上げし、遠景・細部の鏡面のちらつきを抑える |
| リムライト | `_DhkUseRim` | 掠め角の縁を加算発光させる。HDR 色で盛った分は Bloom が拾う |
| 両面描画 | `_DhkCull` | Back / Front / Off。草・葉などの板ポリ用。影とデプスのパスにも効く。裏面の法線は反転しない（Standard と同じ） |

新しいプロパティの名前は dhk 固有にしてある（`_DhkCull` など）。他のシェーダーから変換したマテリアルに
残っている `_Cull` / `_UseRim` などの値が、勝手に効き始めないようにするため。

`_SpecularHighlightsOff` は Unity Standard と同じく直接光の鏡面だけを消す（環境反射は残る）。
`_GlossyReflectionsOff` は環境反射をフラットな色に置き換える。

## Quest 版で無視される機能

Quest 版は拡散とライトマップに絞った軽量版で、次を読まない:
MonoSH / バイキュービック / 鏡面（スペキュラ・環境反射）/ Light Volumes / ディテールマップ /
スペキュラ強調 / GSAA / リムライト。
アルベド・Alpha Cutout・エミッション・`_DhkCull` は PC 版と同じ名前で効くので、PC 版からコピーした値がそのまま使える。

## 1.4.x からの移行

- シェーダーの GUID は変わっていない。パッケージを更新するだけでよい
- `_BICUBICLIGHTMAP_ON` / `_SPECULARHIGHLIGHTS_OFF` / `_GLOSSYREFLECTIONS_OFF` / `_MONOSHSPEC_ON` は
  キーワードではなくトグルの値で判定するようになった。値はそのまま引き継がれ、残ったキーワードは無害
- 既定値のマテリアルの見た目は 1.4.x と同じ。新機能はどれも既定で OFF

## シェーダーを改造する人へ

本体は `Runtime/Shaders/dhkStandardCore.cginc` にあり、`dhkStandard.shader` は Properties と `#pragma` だけにしてある。
ビルド時のコンパイル指示は「.shader の本文 × キーワードの列挙数（≒ 2^shader_feature 本数 × 4）」の大きさで
ワーカーへ送られ、本文が大きい一枚岩のシェーダーはワーカーを落とす。include はこの大きさに含まれない。

- コードは `.cginc` に書き、`.shader` を太らせない
- `shader_feature` を1本足すごとに大きさが倍になる。機能の ON/OFF はなるべくユニフォーム分岐で書く
- ユニフォーム分岐の中では `tex2D` のような暗黙の勾配を使うサンプルを避ける（`tex2Dlod` か、分岐の外で ddx/ddy を取って `tex2Dgrad`）

## Mochie が入っているプロジェクトでの利点

Mochie は同梱のエディタスクリプトで **Unity 標準 Standard のマテリアルを
`Mochie/Standard Lite` / `Standard Mobile` に自動で差し替える**。
配布物のマテリアルを Standard で作ると、導入先で勝手に書き換えられて Mochie 依存が生える。
このシェーダーは Mochie の標的外なので、その事故を避けられる。

## 注意: GUID は固定

`dhkStandard.shader` の GUID は `0f1e2d3c4b5a697887960a5b4c3d2e1f` に固定してある
（複数プロジェクトでマテリアル参照を保つため、手動で揃えたもの）。
**同じプロジェクトにこのパッケージと `Assets/` 配下のコピーを同時に置いてはいけない。GUID が衝突する。**
パッケージを入れたら、そのプロジェクトの `Assets/you5248/Shaders/dhkStandard.shader` は削除すること。
GUID が同じなので、削除してもマテリアルの参照は切れない。

## 導入

### VCC から入れる（推奨）

VCC → **Settings** → **Packages** → **Add Repository** に次を登録する。

```
https://you5248.github.io/vpm-listing/index.json
```

以後、各プロジェクトの **Manage Project** から **dhk Shaders** を追加できる。

### git clone で入れる

```sh
cd "<プロジェクト>/Packages"
git clone https://github.com/you5248/dhk-shaders.git com.you5248.dhk-shaders
```

フォルダ名は必ず `com.you5248.dhk-shaders` にすること。

## リリース手順（メンテナ向け）

`Runtime/Shaders/dhkPackages.cginc` は Editor スクリプトがローカルで書き換える**生成ファイル**で、
リポジトリには **define を含まないスタブ**をコミットしてある。
連携先が入っている作業環境では起動後に define 入りへ書き換わるが、それをコミットしてはいけない
（連携先が無いプロジェクトで include に失敗する）。
作業クローンでは `git update-index --skip-worktree Runtime/Shaders/dhkPackages.cginc` で
ローカルの書き換えを git から隠してある。

リリース前に次が `DHK_PACKAGES_INCLUDED` 以外を出さないことを確認する。

```sh
git show HEAD:Runtime/Shaders/dhkPackages.cginc | grep '^#define'
```

zip は `git archive --format=zip -o com.you5248.dhk-shaders-<ver>.zip HEAD` で作り
（ルートに `package.json` が来る）、`gh release create v<ver> <zip>` で添付する。
その後 `vpm-listing` で `python tools/build_index.py` を実行して push する。

## 第三者由来のコード

Unity Built-in Shaders に由来する部分（GI の合成、ライティングモデル）は MIT License。
対象と全文は [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) にある。
バイキュービック補間（GPU Gems 2 ch.20）・MonoSH（Geomerics）・GSAA（法線分散フィルタリング）は、
公開された手法を独自に実装したもの。

## MonoSH の実装について（出所）

MonoSH の拡散評価には、Geomerics が公開した L1 球面調和のノンリニア評価式を用いている。

- Geomerics, *Reconstructing Diffuse Lighting from Spherical Harmonic Data* (CEDEC 2015)
  <http://www.geomerics.com/wp-content/uploads/2015/08/CEDEC_Geomerics_ReconstructingDiffuseLighting1.pdf>
- ARM, *Simplifying Spherical Harmonics for Lighting*（同式の導出）

入力は「明るさを `unity_Lightmap`、正規化 L1 ベクトルを `unity_LightmapInd` に 0..1 で入れる」
という **MonoSH ベイクのテクスチャ配置を読む**もので、この配置に合わせている（相互運用）。
評価式は上記の公開資料をもとに自前で実装している。

MonoSH では全チャンネルが同じ方向ベクトルを共有するため、`L1 = 2 * nL1 * L0` を
Geomerics 式へ入れると `R0` が約分され、`q` / `p` / `a` がチャンネルに依らない共通係数になる。
そのため実装は

```
sh = L0 * factor(nL1, N)
```

の一本にまとめてある。輝度を別途作って比を掛け戻す必要はない。
