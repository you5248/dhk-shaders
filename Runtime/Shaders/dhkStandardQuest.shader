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
        _MetallicGlossMap ("Packed Map", 2D) = "white" {}
        _GlossMapScale ("Smoothness Map Scale", Range(0,1)) = 1
        // Packed map channel layout. Defaults match Unity Standard so existing
        // materials are unchanged. The ShaderGUI writes these one-hot masks.
        [HideInInspector] _PackedPreset ("", Float) = 0
        [HideInInspector] _MetallicChannelMask ("", Vector) = (1,0,0,0)
        [HideInInspector] _SmoothnessChannelMask ("", Vector) = (0,0,0,1)
        [HideInInspector] _OcclusionChannelMask ("", Vector) = (0,0,0,0)
        [HideInInspector] _SmoothnessIsRoughness ("", Float) = 0

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
        #pragma surface surf Lambert noforwardadd noshadow nolppv dithercrossfade vertex:dhkVert exclude_path:deferred exclude_path:prepass
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

        // Per-texture Tiling/Offset. Using uv_MainTex would force every map to be
        // sampled with _MainTex's ST, so pass one raw UV and apply each _ST in surf.
        float4 _MainTex_ST;
        float4 _MetallicGlossMap_ST;
        float4 _BumpMap_ST;
        float4 _OcclusionMap_ST;
        float4 _EmissionMap_ST;

        fixed4 _Color;
        half4 _MetallicChannelMask;
        half4 _OcclusionChannelMask;
        half _Cutoff;
        half _Metallic;
        half _Glossiness;
        half _GlossMapScale;
        half _BumpScale;
        half _OcclusionStrength;
        fixed4 _EmissionColor;

        // Raw texcoord0. The name must not start with uv_, otherwise the surface
        // shader generator would pre-transform it with that texture's ST.
        struct Input
        {
            float2 dhkUV;
        };

        void dhkVert(inout appdata_full v, out Input o)
        {
            UNITY_INITIALIZE_OUTPUT(Input, o);
            o.dhkUV = v.texcoord.xy;
        }

        void surf(Input IN, inout SurfaceOutput o)
        {
            // The dither clip for LOD Cross-Fade is injected into every generated pass
            // by the dithercrossfade option on #pragma surface.

            fixed4 albedo = tex2D(_MainTex, TRANSFORM_TEX(IN.dhkUV, _MainTex)) * _Color;
            #if defined(_ALPHATEST_ON)
                clip(albedo.a - _Cutoff);
            #endif

            half metallic = _Metallic;
            half packedAoActive = 0;
            half packedAo = 1;
            #if defined(_METALLICGLOSSMAP)
                fixed4 mg = tex2D(_MetallicGlossMap, TRANSFORM_TEX(IN.dhkUV, _MetallicGlossMap));
                // Must not multiply by _Metallic: it defaults to 0, which made the map
                // a no-op. Channel selection uses the same one-hot mask as the PC shader.
                metallic = dot(mg, _MetallicChannelMask);
                packedAoActive = saturate(dot(_OcclusionChannelMask, half4(1, 1, 1, 1)));
                packedAo = dot(mg, _OcclusionChannelMask);
                // Smoothness (_Glossiness / _GlossMapScale) intentionally unused on Quest.
            #endif

            // Metallic darkens diffuse only — no specular term on Quest.
            o.Albedo = albedo.rgb * (1.0h - metallic);
            o.Alpha = albedo.a;
            o.Specular = 0;
            o.Gloss = 0;
            o.Emission = 0;

            #if defined(_NORMALMAP)
                o.Normal = UnpackScaleNormal(tex2D(_BumpMap, TRANSFORM_TEX(IN.dhkUV, _BumpMap)), _BumpScale);
            #endif

            // Packed AO wins; never sample both.
            if (packedAoActive > 0.5h)
            {
                o.Albedo *= lerp(1.0h, packedAo, _OcclusionStrength);
            }
            #if defined(_OCCLUSIONMAP)
            else
            {
                half occ = tex2D(_OcclusionMap, TRANSFORM_TEX(IN.dhkUV, _OcclusionMap)).g;
                o.Albedo *= lerp(1.0h, occ, _OcclusionStrength);
            }
            #endif

            #if defined(_EMISSION)
                o.Emission = tex2D(_EmissionMap, TRANSFORM_TEX(IN.dhkUV, _EmissionMap)).rgb * _EmissionColor.rgb;
            #endif
        }
        ENDCG
    }
    FallBack Off
    CustomEditor "you5248.DhkShadersEditor.DhkStandardGUI"
}
