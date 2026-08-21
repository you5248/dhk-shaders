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

> ⚠ **ShaderGUI を持たないため、マップ系は `[Toggle]` で明示的に ON にする必要がある。**
> 例: ノーマルマップは `_BumpMap` にテクスチャを入れるだけでは効かない。
> 「ノーマルマップを使用」（`_UseNormalMap` → キーワード `_NORMALMAP`）を ON にすること。
> Metallic/Smoothness マップ（`_METALLICGLOSSMAP`）、Alpha Cutout（`_ALPHATEST_ON`）等も同様。

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
