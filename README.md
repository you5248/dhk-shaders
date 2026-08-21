# dhk Shaders

Unityビルトイン（BiRP / Forward）向けの**軽量Standard互換シェーダー**。
旧 White House プロジェクト製。汎用ツールとして you5248 配下に常備しているもの。

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
- LightVolume や追加 BRDF を持たないぶん **Mochie / Filamented より軽い**

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

## 他プロジェクトでの使い方

```sh
cd "<移したいプロジェクト>/Packages"
git clone <このリポジトリのURL> com.you5248.dhk-shaders
```

フォルダ名は必ず `com.you5248.dhk-shaders` にすること。
