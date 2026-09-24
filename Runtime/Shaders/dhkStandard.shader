// you5248 / dhk Standard (Bicubic Lightmap)
// -----------------------------------------------------------------------------
// Unity ビルトイン（Forward）向けの軽量 Standard 互換シェーダー。
//   ・Standard と同じ PBR ライティング（Unity 本体の BRDF / 全ライトパス / 影 / メタパス）。
//     既定値では Standard と同じ結果になる
//   ・追加機能: ライトマップをバイキュービック 4 タップでサンプリングし、
//              低解像度ベイクのブロック段差（ベイク跡）をなだらかにする
//   ・LOD Cross-Fade（ディザ）対応: LODGroup の Fade Mode = Cross Fade で
//              LOD 切替時にメッシュがディザパターンで滑らかに入れ替わる（ポップ抑制）
//
// 設計メモ:
//   BRDF は Unity の UNITY_BRDF_PBS をそのまま使い、GI フック（LightingStandardBicubic_GI）で
//   ライトマップのサンプリングと Light Volumes の合成を差し替える。追加機能（ディテール /
//   スペキュラ強調 / GSAA / リム / LV スペキュラ / LV 影マスク）は既定で OFF か無効値で、
//   OFF のときの追加コストはユニフォーム分岐の判定だけ。
//   本体は dhkStandardCore.cginc にある（.shader を薄く保つ理由は同ファイル冒頭を参照）。
//
//   プロパティ名は Unity Standard と一致させてあるので、Standard マテリアルから
//   このシェーダーに差し替えても各値（色・metallic・smoothness 等）は維持される。
//   ※ マップ系は [Toggle] キーワードで明示的に ON にする方式。専用の ShaderGUI
//     （you5248.DhkShadersEditor.DhkStandardGUI）が OFF の項目を畳み、Standard から
//     乗り換えた際は割り当て済みマップからトグルを推測して立てる。
// -----------------------------------------------------------------------------
// -----------------------------------------------------------------------------
//  由来と表示
//  ・dhkStandardCore.cginc の GI の合成（dhk_UnityGI_Base / dhk_GlobalIllumination）は、
//    Unity Built-in Shaders の UnityGlobalIllumination.cginc（UnityGI_Base / UnityGlobalIllumination）を
//    基に、ライトマップの取得と MonoSH / Light Volumes の分岐を差し込んだ改変物。
//    ライティングモデル（LightingStandardBicubic / _GI）は UnityPBSLighting.cginc の
//    LightingStandard / LightingStandard_GI を展開したもの。
//    Copyright (c) 2016 Unity Technologies. MIT License（THIRD_PARTY_NOTICES.md を参照）
//  ・バイキュービック補間は GPU Gems 2 ch.20（Sigg & Hadwiger）の公開手法を独自に実装したもの
//  ・MonoSH の拡散評価は Geomerics（CEDEC 2015）の公開資料の式を独自に実装したもの
//  ・GSAA は法線分散フィルタリング（Kaplanyan ら / Tokuyoshi & Kaplanyan）の系統の独自実装
// -----------------------------------------------------------------------------
Shader "you5248/dhk Standard (Bicubic Lightmap)"
{
    Properties
    {
        _Color ("Color", Color) = (1,1,1,1)
        _MainTex ("Albedo (RGB)", 2D) = "white" {}

        [Space]
        [Toggle(_ALPHATEST_ON)] _AlphaTest ("Alpha Cutout を有効化", Float) = 0
        _Cutoff ("  Alpha Cutoff", Range(0,1)) = 0.5

        [Space]
        [Gamma] _Metallic ("Metallic", Range(0,1)) = 0
        _Glossiness ("Smoothness", Range(0,1)) = 0.5
        [Toggle(_METALLICGLOSSMAP)] _UseMetallicMap ("Metallic/Smoothness マップを使用", Float) = 0
        _MetallicGlossMap ("  パックマップ", 2D) = "white" {}
        _GlossMapScale ("  Smoothness Map Scale", Range(0,1)) = 1.0
        // パックマップのチャンネル割り当て。ShaderGUI のプリセットが one-hot マスクを書く。
        // 既定は Unity Standard 互換（Metallic=R / Smoothness=A / AO はパックから取らない）
        // なので、既存マテリアルの見た目は変わらない。
        [HideInInspector] _PackedPreset ("", Float) = 0
        [HideInInspector] _MetallicChannelMask ("", Vector) = (1,0,0,0)
        [HideInInspector] _SmoothnessChannelMask ("", Vector) = (0,0,0,1)
        [HideInInspector] _OcclusionChannelMask ("", Vector) = (0,0,0,0)
        [HideInInspector] _SmoothnessIsRoughness ("", Float) = 0

        [Space]
        [Toggle(_NORMALMAP)] _UseNormalMap ("ノーマルマップを使用", Float) = 0
        [Normal] _BumpMap ("  Normal Map", 2D) = "bump" {}
        _BumpScale ("  Normal Scale", Float) = 1.0

        [Space]
        [Toggle(_OCCLUSIONMAP)] _UseOcclusionMap ("オクルージョンマップを使用", Float) = 0
        _OcclusionMap ("  Occlusion (G)", 2D) = "white" {}
        _OcclusionStrength ("  Occlusion Strength", Range(0,1)) = 1.0

        [Space]
        [Toggle(_EMISSION)] _UseEmission ("エミッションを使用", Float) = 0
        [HDR] _EmissionColor ("  Emission Color", Color) = (0,0,0)
        _EmissionMap ("  Emission Map", 2D) = "white" {}

        [Space]
        // ディテールの各マップ（Mask を含む）は自分の Tiling/Offset を持つ。
        // Unity Standard は全ディテールが Detail Albedo の ST を共有し、Mask はメインの ST で読む点が違う
        [Toggle(_DHKDETAIL_ON)] _UseDetail ("ディテールマップを使用", Float) = 0
        _DetailAlbedoMap ("  Detail Albedo", 2D) = "grey" {}
        [Enum(MulX2 Standard,0,Multiply,1,Add,2,Overlay,3,Replace,4)]
        _DetailAlbedoBlend ("  Albedo 合成モード", Float) = 0
        _DetailAlbedoStrength ("  Albedo の効き", Range(0, 1)) = 1.0
        [Normal] _DetailNormalMap ("  Detail Normal", 2D) = "bump" {}
        _DetailNormalMapScale ("  Detail Normal Scale", Range(0, 4)) = 1.0
        _DetailMetallicGlossMap ("  Detail Metallic(R) Smoothness(A) 乗算", 2D) = "white" {}
        _DetailMSStrength ("  Metallic Smoothness の効き", Range(0, 1)) = 1.0
        _DetailOcclusionMap ("  Detail Occlusion (G)", 2D) = "white" {}
        _DetailOcclusionStrength ("  Detail Occlusion Strength", Range(0, 1)) = 1.0
        _DetailMask ("  Detail Mask (A)", 2D) = "white" {}
        _DetailMaskStrength ("  Mask の効き (0=マスク無視)", Range(0, 1)) = 1.0

        [Space]
        [Header(Bake Smoothing)]
        [ToggleUI] _BicubicLightmap ("バイキュービック・ライトマップ (ベイク跡をなだらかに)", Float) = 1

        [Space]
        [Header(MonoSH  houkou tsuki lightmap wo tsukau)]
        [Toggle(_MONOSH_ON)] _UseMonoSH ("MonoSH (方向つきライトマップ)", Float) = 0
        [ToggleUI] _UseMonoSHSpec ("  ベイクスペキュラ (焼いた光の艶)", Float) = 0
        _MonoSHSpecMul ("  ベイクスペキュラ強さ", Range(0,2)) = 1
        [ToggleUI] _MonoSHNonlinear ("  ノンリニア補正 (推奨 ON)", Float) = 1

        [Space]
        [Header(VRC Light Volumes)]
        [ToggleUI] _UseLightVolumes ("Light Volumes を使う", Float) = 1
        _LightVolumeBias ("  サンプル位置を法線方向へずらす (漏光対策)", Range(0, 0.2)) = 0
        // 通常（ベイク済み）LightVolume にリアルタイム Directional の影(atten)を掛けて
        // 「ベイクしたような濃い影」を出す（VRC Light Volumes 3.x のみ。2.x では無効）。
        // 加算ボリューム（蛍など）と Point Light Volume（ランタン）には掛けない＝
        // 提灯の光が太陽の影で消える不自然を避ける
        _LVShadowMulStrength ("  リアルタイム影を掛ける強さ (LV 3.x / 0=OFF)", Range(0, 1)) = 0
        _LVShadowFloor ("  影の中に残す明るさ (0だとバウンスまで消えて真っ黒)", Range(0, 1)) = 0.25
        // Point Light Volume を面の向きでどれだけ絞るか（LV 3.x のみ）。0 は向きを見ない＝1.4.x と同じ。
        // LV 3.x 自身の既定は 3（光源の反対を向いた面には当たらない）
        _LVPointLightShading ("  PLV を面の向きで絞る (LV 3.x / 0=向きを見ない)", Range(0, 3)) = 0
        // LV の L1(方向) から作る艶。ベイク光・蛍・PLV の光源方向にハイライトが出る。
        // f0 適用済みの最終色を BRDF の後で加算する方式（gi.indirect.specular 経由は二重フレネルで金属破綻）
        _LVSpecularMul ("  LVスペキュラ (0=OFF)", Range(0, 2)) = 0

        [Space]
        [Header(Specular)]
        // F0（鏡面反射率の芯）だけを持ち上げる誇張ノブ。拡散は触らないので明るさの土台は変わらない。
        // 夜シーンなど Directional を絞った環境で「艶だけ効かせたい」用途
        _SpecBoost ("スペキュラ強調 (1=物理どおり)", Range(1, 8)) = 1
        // GSAA: 法線の画面内変化率ぶん粗さを底上げし、遠距離・細部の鏡面ちらつき(明滅)を抑える。
        // スペキュラ強調と併用すると「ギラつかせてもジラジラしない」
        [ToggleUI] _UseGSAA ("GSAA (鏡面エイリアシング低減)", Float) = 0
        _GsaaVariance ("  Variance (効き方の斜度)", Range(0, 1)) = 0.15
        _GsaaThreshold ("  Max Roughness Add (効きの上限)", Range(0, 1)) = 0.18

        [Space]
        [Header(Rim Light)]
        // 視線と法線の掠め角で縁が発光する。HDR色×強度で1.0を超えた分は bloom が拾って
        // 「ピカーッ」になる（bloom 無しでも白く飛ぶ縁は出る）
        [ToggleUI] _DhkUseRim ("リムライトを使用", Float) = 0
        [HDR] _DhkRimColor ("  Rim Color (HDRで盛るほど bloom が食う)", Color) = (1, 1, 1, 1)
        _DhkRimIntensity ("  Rim Intensity", Range(0, 16)) = 2
        _DhkRimPower ("  Rim Power (大きいほど縁だけ細く)", Range(0.5, 16)) = 4
        _DhkRimLightMask ("  ライトに従う (0=常時 / 1=光の当たる側だけ)", Range(0, 1)) = 0

        [Space]
        [Header(Performance)]
        [ToggleUI] _SpecularHighlightsOff ("スペキュラハイライトを無効化", Float) = 0
        [ToggleUI] _GlossyReflectionsOff ("リフレクション(環境マップ)を無効化", Float) = 0
        // 両面を描く板ポリ（草・葉・薄い布）用。Off で裏面も描く。影とデプスのパスにも同じ値が効く
        [Enum(UnityEngine.Rendering.CullMode)] _DhkCull ("カリング (Back=通常 / Off=両面)", Float) = 2
    }

    SubShader
    {
        Tags { "RenderType"="Opaque" "Queue"="Geometry" }
        LOD 200
        Cull [_DhkCull]

        CGPROGRAM
        #pragma surface surf StandardBicubic fullforwardshadows addshadow dithercrossfade vertex:dhkVert exclude_path:deferred exclude_path:prepass
        #pragma target 4.0
        #pragma multi_compile_instancing
        #pragma multi_compile _ LOD_FADE_CROSSFADE
        #pragma shader_feature_local _ALPHATEST_ON
        #pragma shader_feature_local _METALLICGLOSSMAP
        #pragma shader_feature_local _NORMALMAP
        #pragma shader_feature_local _OCCLUSIONMAP
        #pragma shader_feature_local _EMISSION
        #pragma shader_feature_local _DHKDETAIL_ON
        #pragma shader_feature_local _MONOSH_ON

        #include "dhkStandardCore.cginc"

        ENDCG
    }

    FallBack "Standard"
    CustomEditor "you5248.DhkShadersEditor.DhkStandardGUI"
}
