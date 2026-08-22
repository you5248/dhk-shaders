# dhk Shaders

Unityビルトイン（BiRP / Forward）向けの**軽量Standard互換シェーダー**。

| シェーダー | 用途 |
|---|---|
| `you5248/dhk Standard (Bicubic Lightmap)` | PC向け本命 |
| `you5248/Quest/dhk Standard` | Quest（Android）向け軽量版 |

## 何が違うのか

- **ライティングは Unity 標準の Standard そのもの**（本体の BRDF / 全ライトパス / 影 / メタパス）
- **バイキュービック 4 タップのライトマップサンプリング** — 低解像度ベイクのブロック段差をならす。
  追加コストは「ライトマップがある時に参照が 1 → 4 タップに増える」だけ
- **MonoSH**（指向性ライトマップ）対応 — ライトマップからスペキュラ／ノーマル反応を出す
- **LOD Cross-Fade（ディザ）対応** — LODGroup の Fade Mode = Cross Fade で切替のポップを抑える
- 鏡面の Light Volumes や追加の BRDF を持たないぶん **Mochie / Filamented より軽い**（拡散 LV には対応）

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

## VRC Light Volumes（拡散）

`red.sim.lightvolumes` が入っているプロジェクトでは、インスペクタに
「VRC Light Volumes」欄が出る（入っていなければ出ない）。

- ライトマップあり → 加算ボリュームだけを足す（ベイクとの二重計上を避ける）
- ライトマップなし → Unity の SH を置き換える
- `サンプル位置を法線方向へずらす` は漏光対策。既定 0

**鏡面には対応していない。** `LightVolumeSpecular` は f0 適用済みの最終反射色を返すため、
GI に足すと Unity の BRDF がフレネルを二重に掛けて金属が破綻する。
拡散のみを扱う（詳細は CHANGELOG 1.3.0）。

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

`_MainTex` / `_MetallicGlossMap` / `_BumpMap` / `_OcclusionMap` / `_EmissionMap` は
**それぞれ独立した Tiling/Offset を持つ**。生の UV を1本だけ渡し、
サーフェス側で各 `_ST` を適用しているため、補間子はバリアントによらず一定。

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
git show HEAD:Runtime/Shaders/dhkPackages.cginc | grep define
```

zip は `git archive --format=zip -o com.you5248.dhk-shaders-<ver>.zip HEAD` で作り
（ルートに `package.json` が来る）、`gh release create v<ver> <zip>` で添付する。
その後 `vpm-listing` で `python tools/build_index.py` を実行して push する。

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
