// Quest-only counterpart of you5248/dhk Standard (Bicubic Lightmap).
// Property names intentionally match the PC shader so a copied material keeps
// its albedo/PBR values. Bicubic lightmaps, Bakery MonoSH, specular, and
// reflection probes are omitted — diffuse + lightmap focused.
Shader "you5248/Quest/dhk Standard"
{
    Properties
    {
        _Color ("Color", Color) = (1,1,1,1)
        _MainTex ("Albedo (RGB)", 2D) = "white" {}

        [Toggle(_ALPHATEST_ON)] _AlphaTest ("Alpha Cutout", Float) = 0
        _Cutoff ("Alpha Cutoff", Range(0,1)) = 0.5

        // Kept for PC -> Quest material copy compatibility (lighting ignores Smoothness).
        [Gamma] _Metallic ("Metallic", Range(0,1)) = 0
        _Glossiness ("Smoothness", Range(0,1)) = 0.5
        [Toggle(_METALLICGLOSSMAP)] _UseMetallicMap ("Use Metallic/Smoothness Map", Float) = 0
        _MetallicGlossMap ("Metallic (R) / Smoothness (A)", 2D) = "white" {}
        _GlossMapScale ("Smoothness Map Scale", Range(0,1)) = 1

        [Toggle(_NORMALMAP)] _UseNormalMap ("Use Normal Map", Float) = 0
        [Normal] _BumpMap ("Normal Map", 2D) = "bump" {}
        _BumpScale ("Normal Scale", Float) = 1

        [Toggle(_OCCLUSIONMAP)] _UseOcclusionMap ("Use Occlusion Map", Float) = 0
        _OcclusionMap ("Occlusion (G)", 2D) = "white" {}
        _OcclusionStrength ("Occlusion Strength", Range(0,1)) = 1

        [Toggle(_EMISSION)] _UseEmission ("Use Emission", Float) = 0
        [HDR] _EmissionColor ("Emission Color", Color) = (0,0,0,0)
        _EmissionMap ("Emission Map", 2D) = "white" {}

        // Serialized for clean PC -> Quest material copies, but deliberately unused.
        [HideInInspector] _BicubicLightmap ("PC Bicubic (unused)", Float) = 0
        [HideInInspector] _SpecularHighlightsOff ("PC Specular Off (unused)", Float) = 0
        [HideInInspector] _GlossyReflectionsOff ("PC Reflections Off (unused)", Float) = 0
    }

    SubShader
    {
        Tags { "RenderType"="Opaque" "Queue"="Geometry" }
        LOD 150

        CGPROGRAM
        // Quest: baked lightmaps/probes, diffuse only (no specular / reflection probes).
        // Do not generate ForwardAdd, realtime-shadow, deferred, or prepass variants.
        #pragma surface surf Lambert noforwardadd noshadow nolppv exclude_path:deferred exclude_path:prepass
        #pragma target 3.5
        #pragma multi_compile_instancing
        #pragma multi_compile _ LOD_FADE_CROSSFADE
        // Quest does not use directional / MonoSH L1 lightmaps.
        #pragma skip_variants DIRLIGHTMAP_COMBINED DIRLIGHTMAP_SEPARATE

        #pragma shader_feature_local _ALPHATEST_ON
        #pragma shader_feature_local _METALLICGLOSSMAP
        #pragma shader_feature_local _NORMALMAP
        #pragma shader_feature_local _OCCLUSIONMAP
        #pragma shader_feature_local _EMISSION

        #include "UnityCG.cginc"

        sampler2D _MainTex;
        sampler2D _MetallicGlossMap;
        sampler2D _BumpMap;
        sampler2D _OcclusionMap;
        sampler2D _EmissionMap;

        fixed4 _Color;
        half _Cutoff;
        half _Metallic;
        half _Glossiness;
        half _GlossMapScale;
        half _BumpScale;
        half _OcclusionStrength;
        fixed4 _EmissionColor;

        struct Input
        {
            float2 uv_MainTex;
            float4 screenPos;
        };

        void surf(Input IN, inout SurfaceOutput o)
        {
            #if defined(LOD_FADE_CROSSFADE)
                UnityApplyDitherCrossFade(
                    IN.screenPos.xy / max(IN.screenPos.w, 1e-5) * _ScreenParams.xy);
            #endif

            fixed4 albedo = tex2D(_MainTex, IN.uv_MainTex) * _Color;
            #if defined(_ALPHATEST_ON)
                clip(albedo.a - _Cutoff);
            #endif

            half metallic = _Metallic;
            #if defined(_METALLICGLOSSMAP)
                fixed4 mg = tex2D(_MetallicGlossMap, IN.uv_MainTex);
                metallic = mg.r * _Metallic;
                // Smoothness (mg.a / _Glossiness / _GlossMapScale) intentionally unused.
            #endif

            // Metallic darkens diffuse only — no specular term on Quest.
            o.Albedo = albedo.rgb * (1.0h - metallic);
            o.Alpha = albedo.a;
            o.Specular = 0;
            o.Gloss = 0;
            o.Normal = half3(0, 0, 1);
            o.Emission = 0;

            #if defined(_NORMALMAP)
                o.Normal = UnpackScaleNormal(tex2D(_BumpMap, IN.uv_MainTex), _BumpScale);
            #endif

            #if defined(_OCCLUSIONMAP)
                half occ = tex2D(_OcclusionMap, IN.uv_MainTex).g;
                o.Albedo *= lerp(1.0h, occ, _OcclusionStrength);
            #endif

            #if defined(_EMISSION)
                o.Emission = tex2D(_EmissionMap, IN.uv_MainTex).rgb * _EmissionColor.rgb;
            #endif
        }
        ENDCG
    }
    FallBack Off
}
