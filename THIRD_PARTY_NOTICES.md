# Third-party notices

このパッケージのコードのうち、第三者由来の部分とそのライセンス。

## Unity Built-in Shaders

- 対象1: `Runtime/Shaders/dhkStandardCore.cginc` の `dhk_UnityGI_Base` / `dhk_GlobalIllumination`
  - 由来: Unity Built-in Shaders の `UnityGlobalIllumination.cginc`（`UnityGI_Base` / `UnityGlobalIllumination`）を基に、
    ライトマップの取得をバイキュービック補間へ差し替え、MonoSH と VRC Light Volumes の分岐を差し込んだ改変物
- 対象2: `Runtime/Shaders/dhkStandardCore.cginc` の `LightingStandardBicubic` / `LightingStandardBicubic_GI`
  - 由来: Unity Built-in Shaders の `UnityPBSLighting.cginc`（`LightingStandard` / `LightingStandard_GI`）を展開し、
    スペキュラ強調・GSAA・リムライト・LV スペキュラの割り込み点を加えた改変物
- ライセンス: MIT License

```
Copyright (c) 2016 Unity Technologies

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

## 参考文献（コードの複製ではなく、公開された手法・式の独自実装）

- バイキュービック補間: C. Sigg, M. Hadwiger, "Fast Third-Order Texture Filtering", GPU Gems 2, ch. 20 (2005)
- MonoSH の拡散評価: Geomerics, "Reconstructing Diffuse Lighting from Spherical Harmonic Data", CEDEC 2015
- GSAA（法線の画面内の変化量で粗さを底上げする。論文の式を簡略化した弱めの独自の変形で、分散を粗さの二乗に足している）:
  A. S. Kaplanyan, S. Hill, A. Patney, A. Lefohn,
  "Filtering Distributions of Normals for Shading Antialiasing", HPG 2016 /
  Y. Tokuyoshi, A. S. Kaplanyan, "Improved Geometric Specular Antialiasing", I3D 2019
