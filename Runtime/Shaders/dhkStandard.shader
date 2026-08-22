// you5248 / dhk Standard (Bicubic Lightmap)
// -----------------------------------------------------------------------------
// Unity ビルトイン（Forward）向けの軽量 Standard 互換シェーダー。
//   ・Standard と同じ PBR ライティング（Unity 本体の BRDF / 全ライトパス / 影 / メタパス）
//   ・追加機能: ライトマップをバイキュービック 4 タップでサンプリングし、
//              低解像度ベイクのブロック段差（ベイク跡）をなだらかにする
//   ・LOD Cross-Fade（ディザ）対応: LODGroup の Fade Mode = Cross Fade で
//              LOD 切替時にメッシュがディザパターンで滑らかに入れ替わる（ポップ抑制）
//
// 設計メモ:
//   Standard ライティングを丸ごと Unity に任せ、GI フック（LightingStandardBicubic_GI）
//   でライトマップのサンプリングだけを差し替える。これにより自作コードは最小で、
//   コストは「ライトマップがある時にライトマップ参照が 1 → 4 タップに増える」だけ。
//   鏡面の LightVolume や追加の BRDF を持たないため Mochie / Filamented より軽い
//   （拡散の Light Volumes には対応している）。
//
//   プロパティ名は Unity Standard と一致させてあるので、Standard マテリアルから
//   このシェーダーに差し替えても各値（色・metallic・smoothness 等）は維持される。
//   ※ マップ系は [Toggle] キーワードで明示的に ON にする方式。専用の ShaderGUI
//     （you5248.DhkShadersEditor.DhkStandardGUI）が OFF の項目を畳み、Standard から
//     乗り換えた際は割り当て済みマップからトグルを推測して立てる。
// -----------------------------------------------------------------------------
// -----------------------------------------------------------------------------
//  由来と表示
//  ・GI の合成（dhk_UnityGI_Base / dhk_GlobalIllumination）は、Unity Built-in Shaders の
//    UnityGlobalIllumination.cginc（UnityGI_Base / UnityGlobalIllumination）を基に、
//    ライトマップの取得と MonoSH / Light Volumes の分岐を差し込んだ改変物。
//    Copyright (c) 2016 Unity Technologies. MIT License（THIRD_PARTY_NOTICES.md を参照）
//  ・バイキュービック補間は GPU Gems 2 ch.20（Sigg & Hadwiger）の公開手法を独自に実装したもの
//  ・MonoSH の拡散評価は Geomerics（CEDEC 2015）の公開資料の式を独自に実装したもの
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
        [Header(Bake Smoothing)]
        [Toggle(_BICUBICLIGHTMAP_ON)] _BicubicLightmap ("バイキュービック・ライトマップ (ベイク跡をなだらかに)", Float) = 1

        [Space]
        [Header(MonoSH  houkou tsuki lightmap wo tsukau)]
        [Toggle(_MONOSH_ON)] _UseMonoSH ("MonoSH (方向つきライトマップ)", Float) = 0
        [Toggle(_MONOSHSPEC_ON)] _UseMonoSHSpec ("  ベイクスペキュラ (焼いた光の艶)", Float) = 0
        _MonoSHSpecMul ("  ベイクスペキュラ強さ", Range(0,2)) = 1
        [ToggleUI] _MonoSHNonlinear ("  ノンリニア補正 (推奨 ON)", Float) = 1

        [Space]
        [Header(VRC Light Volumes)]
        [ToggleUI] _UseLightVolumes ("Light Volumes を使う", Float) = 1
        _LightVolumeBias ("  サンプル位置を法線方向へずらす (漏光対策)", Range(0, 0.2)) = 0

        [Space]
        [Header(Performance)]
        [Toggle(_SPECULARHIGHLIGHTS_OFF)] _SpecularHighlightsOff ("スペキュラハイライトを無効化", Float) = 0
        [Toggle(_GLOSSYREFLECTIONS_OFF)] _GlossyReflectionsOff ("リフレクション(環境マップ)を無効化", Float) = 0
    }

    SubShader
    {
        Tags { "RenderType"="Opaque" "Queue"="Geometry" }
        LOD 200

        CGPROGRAM
        // Standard ライティングを継承した独自ライティングモデル "StandardBicubic" を使用。
        // exclude_path:deferred / prepass → VRChat は Forward なので Deferred 系は生成せず軽量化。
        #pragma surface surf StandardBicubic fullforwardshadows addshadow dithercrossfade vertex:dhkVert exclude_path:deferred exclude_path:prepass
        #pragma target 4.0
        #pragma multi_compile_instancing
        // LODGroup の Cross Fade（ディザによる LOD 切替フェード）対応。
        // 上の #pragma surface の dithercrossfade がディザ clip を全生成パス
        // （forward / shadow）へ自動で挿入する。手書きの screenPos は不要。
        #pragma multi_compile _ LOD_FADE_CROSSFADE

        // 機能トグル（Inspector の [Toggle] で ON/OFF。ShaderGUI が OFF の項目を畳む）
        #pragma shader_feature_local _ALPHATEST_ON
        #pragma shader_feature_local _METALLICGLOSSMAP
        #pragma shader_feature_local _NORMALMAP
        #pragma shader_feature_local _OCCLUSIONMAP
        #pragma shader_feature_local _EMISSION
        #pragma shader_feature_local _BICUBICLIGHTMAP_ON
        #pragma shader_feature_local _SPECULARHIGHLIGHTS_OFF
        #pragma shader_feature_local _GLOSSYREFLECTIONS_OFF
        #pragma shader_feature_local _MONOSH_ON
        #pragma shader_feature_local _MONOSHSPEC_ON

        #include "UnityPBSLighting.cginc"
        #include "UnityStandardUtils.cginc"

        // 連携パッケージの検出結果（自動生成。相手が無ければ何も define されない）
        #include "dhkPackages.cginc"

        // サーフェスシェーダーは本コンパイルの前に「解析パス」を通す。この解析パスは
        // [fastopt] のような一部の属性を受け付けず、LightVolumes.cginc がそれを含むため
        // 解析パスでは include ごと外す。解析パスは surf の入出力を調べるだけなので、
        // LV のコードが無くても支障はない。
        #if defined(DHK_VRCLV_AVAILABLE) && !defined(SHADER_TARGET_SURFACE_ANALYSIS)
            #define DHK_LV_ACTIVE 1
            #include "Packages/red.sim.lightvolumes/Shaders/LightVolumes.cginc"
        #endif

        // Light Volumes の制御。キーワードにせずユニフォーム分岐にしているのは、
        // shader_feature_local が既に 10 個ありバリアントが 2^10 あるため。
        // LV 側の LightVolumesEnabled() も [branch] 付きの実行時判定なので、
        // LV が無いワールドでは実質コストが乗らない。
        half _UseLightVolumes;
        half _LightVolumeBias;

        // =====================================================================
        //  バイキュービック・ライトマップ・フィルタ
        //  低解像度ライトマップをなめらかに補間してベイクのブロック段差を消す。
        //  3次 B-spline の4つの重みを「隣り合う2テクセルの内分点」2つに畳み込み、
        //  バイリニア4タップで評価する。GPU Gems 2, ch.20
        //  "Fast Third-Order Texture Filtering"（Sigg & Hadwiger, 2005）で公開された手法。
        // =====================================================================

        // 3次 B-spline の基底関数。t は格子間の小数位置（0..1）。w0+w1+w2+w3 = 1。
        void dhk_BSplineWeights(float t, out float w0, out float w1, out float w2, out float w3)
        {
            float t2 = t * t;
            float t3 = t2 * t;
            w0 = (1.0 / 6.0) * (-t3 + 3.0 * t2 - 3.0 * t + 1.0);
            w1 = (1.0 / 6.0) * ( 3.0 * t3 - 6.0 * t2 + 4.0);
            w2 = (1.0 / 6.0) * (-3.0 * t3 + 3.0 * t2 + 3.0 * t + 1.0);
            w3 = (1.0 / 6.0) * t3;
        }

        // unity_Lightmap を texelSize=(w,h,1/w,1/h) でバイキュービック補間
        half4 dhk_SampleLightmapBicubic(float2 uv, float4 texelSize)
        {
            // テクセル中心基準の座標に直し、整数格子 ip と小数位置 t に分ける
            float2 p  = uv * texelSize.xy - 0.5;
            float2 ip = floor(p);
            float2 t  = p - ip;

            float w0x, w1x, w2x, w3x; dhk_BSplineWeights(t.x, w0x, w1x, w2x, w3x);
            float w0y, w1y, w2y, w3y; dhk_BSplineWeights(t.y, w0y, w1y, w2y, w3y);

            // 4 テクセル (ip-1, ip, ip+1, ip+2) を、(ip-1,ip) と (ip+1,ip+2) の2組に分け、
            // 各組は重み比で内分した1点をバイリニアで読む。組の重みは和。
            float gx0 = w0x + w1x, gx1 = w2x + w3x;
            float gy0 = w0y + w1y, gy1 = w2y + w3y;
            float ax = ip.x - 1.0 + w1x / gx0;   // (ip-1, ip) の内分点
            float bx = ip.x + 1.0 + w3x / gx1;   // (ip+1, ip+2) の内分点
            float ay = ip.y - 1.0 + w1y / gy0;
            float by = ip.y + 1.0 + w3y / gy1;

            // テクセル座標 → UV（中心が +0.5）
            float2 uvAA = (float2(ax, ay) + 0.5) * texelSize.zw;
            float2 uvBA = (float2(bx, ay) + 0.5) * texelSize.zw;
            float2 uvAB = (float2(ax, by) + 0.5) * texelSize.zw;
            float2 uvBB = (float2(bx, by) + 0.5) * texelSize.zw;

            half4 rowA = gx0 * UNITY_SAMPLE_TEX2D(unity_Lightmap, uvAA) + gx1 * UNITY_SAMPLE_TEX2D(unity_Lightmap, uvBA);
            half4 rowB = gx0 * UNITY_SAMPLE_TEX2D(unity_Lightmap, uvAB) + gx1 * UNITY_SAMPLE_TEX2D(unity_Lightmap, uvBB);
            return gy0 * rowA + gy1 * rowB;
        }

        // ライトマップ参照を 1 箇所に集約。トグル OFF / 非 D3D11 時は通常のバイリニア。
        half4 dhk_SampleLightmap(float2 uv)
        {
            #if defined(_BICUBICLIGHTMAP_ON) && defined(SHADER_API_D3D11)
                float w, h;
                unity_Lightmap.GetDimensions(w, h);
                float4 texelSize = float4(w, h, 1.0 / w, 1.0 / h);
                return dhk_SampleLightmapBicubic(uv, texelSize);
            #else
                return UNITY_SAMPLE_TEX2D(unity_Lightmap, uv);
            #endif
        }

        // =====================================================================
        //  MonoSH（方向つきライトマップ）
        //
        //  入力の形式:
        //    unity_Lightmap    … 明るさ L0
        //    unity_LightmapInd … 正規化 L1 ベクトル（長さが方向性の強さ）を 0..1 にエンコード
        //  これは MonoSH ベイクが書き出すテクスチャ配置であり、ここではその「配置を読む」
        //  だけを行う。デコード後の評価は下記の公開文献の式を自前で実装している。
        //
        //  拡散の評価式（L1 SH のノンリニア評価）は Geomerics が公開したもの:
        //    Geomerics, "Reconstructing Diffuse Lighting from Spherical Harmonic Data"
        //    (CEDEC 2015)
        //    http://www.geomerics.com/wp-content/uploads/2015/08/
        //        CEDEC_Geomerics_ReconstructingDiffuseLighting1.pdf
        //  ARM "Simplifying Spherical Harmonics for Lighting" にも導出がある。
        //
        //  MonoSH では全チャンネルが同じ方向ベクトルを共有するため、
        //  L1 = 2 * nL1 * L0 を Geomerics 式に入れると R0 が約分され、
        //  q・p・a がチャンネルに依らない共通係数になる。つまり
        //      sh = L0 * factor(nL1, N)
        //  と1つの係数で書ける。輝度を作って比を掛け戻す必要はない。
        // =====================================================================

        /// Geomerics の L1 ノンリニア評価を、MonoSH 用に「共通係数」へ整理したもの。
        /// d は正規化 L1 ベクトル（|d| が方向性の強さ。物理的に 0..1）。
        float dhk_MonoSHFactor(float3 d, float3 n)
        {
            float len2 = dot(d, d);
            if (len2 < 1e-10) return 1.0;          // 方向情報が無い＝等方。係数 1

            float r = saturate(sqrt(len2));        // |R1| / R0 に相当
            float q = saturate(0.5 + 0.5 * dot(d * rsqrt(len2), n));
            float p = 1.0 + 2.0 * r;
            float a = (1.0 - r) / (1.0 + r);
            return a + (1.0 - a) * (p + 1.0) * pow(q, p);
        }

        half _MonoSHNonlinear;

        #if defined(_MONOSH_ON)
        half _MonoSHSpecMul;

        /// L0 と正規化 L1 から拡散と鏡面を作る。
        /// viewDir は面から視点へ向く向き（UnityGIInput.worldViewDir と同じ）。
        void dhk_MonoSH(half3 L0, float2 lmUV, half3 normalWorld, half3 viewDir, half smoothness,
                        out half3 diffuseOut, out half3 specularOut)
        {
            // 0..1 エンコードを [-1,1] へ戻す
            half3 nL1 = UNITY_SAMPLE_TEX2D_SAMPLER(unity_LightmapInd, unity_Lightmap, lmUV).xyz * 2 - 1;

            // 線形評価は L1 = 2*nL1*L0 を代入して整理したもの
            //   sh = L0 + N・L1 = L0 * (1 + 2 * dot(nL1, N))
            half factor = (_MonoSHNonlinear > 0.5)
                        ? (half)dhk_MonoSHFactor(nL1, normalWorld)
                        : (half)(1.0 + 2.0 * dot(nL1, normalWorld));
            diffuseOut = max(L0 * factor, 0.0);

            specularOut = 0;
            #if defined(_MONOSHSPEC_ON)
                // 方向性がゼロなら「どこから来た光か」が無いので鏡面を作らない。
                // 単に normalize() をガードするだけだと halfDir≒viewDir になり、
                // 方向が無いのに視線へ追従する偽の艶が出る。
                float len2 = dot(nL1, nL1);
                if (len2 < 1e-8) return;

                float directionality = saturate(sqrt(len2));
                half3 lightDir = (half3)(nL1 * rsqrt(len2));
                half3 halfDir  = Unity_SafeNormalize(lightDir + viewDir);
                half nh = saturate(dot(normalWorld, halfDir));
                // roughness=0 は GGXTerm が発散するため下限を設ける
                half roughness = max(PerceptualRoughnessToRoughness(SmoothnessToPerceptualRoughness(smoothness)), 0.002);

                // GGX の D 項だけを載せる。フレネルと specColor は後段の Unity BRDF が掛ける。
                // 光量は方向性が強いほど集中するので (1 + 2*d^2) で持ち上げる。
                half3 specLight = L0 * (half)(1.0 + 2.0 * directionality * directionality);
                specularOut = max(GGXTerm(nh, roughness) * specLight, 0.0) * _MonoSHSpecMul;
            #endif
        }
        #endif

        // =====================================================================
        //  GI（Standard の UnityGI_Base 相当をバイキュービックライトマップ版に置換）
        //  ※ベイクライトマップのサンプルだけを差し替え、その他（SH / 方向ライトマップ
        //    デコード / シャドウマスク合成 / 動的ライトマップ）は Standard と同一挙動。
        // =====================================================================
        inline UnityGI dhk_UnityGI_Base(UnityGIInput data, half occlusion, half3 normalWorld, half smoothness)
        {
            UnityGI o_gi;
            ResetUnityGI(o_gi);

            // リアルタイム影とベイク影（シャドウマスク）の合成（Standard と同じ）
            #if defined(HANDLE_SHADOWS_BLENDING_IN_GI)
                half bakedAtten = UnitySampleBakedOcclusion(data.lightmapUV.xy, data.worldPos);
                float zDist = dot(_WorldSpaceCameraPos - data.worldPos, UNITY_MATRIX_V[2].xyz);
                float fadeDist = UnityComputeShadowFadeDistance(data.worldPos, zDist);
                data.atten = UnityMixRealtimeAndBakedShadows(data.atten, bakedAtten, UnityComputeShadowFade(fadeDist));
            #endif

            o_gi.light = data.light;
            o_gi.light.color *= data.atten;

            #if UNITY_SHOULD_SAMPLE_SH
                o_gi.indirect.diffuse = ShadeSHPerPixel(normalWorld, data.ambient, data.worldPos);
            #endif

            #if defined(LIGHTMAP_ON)
                // ★ベイクライトマップをバイキュービックで取得（ここが「ベイク跡なだらか化」）
                half4 bakedColorTex = dhk_SampleLightmap(data.lightmapUV.xy);
                half3 bakedColor = DecodeLightmap(bakedColorTex);

                // MonoSH ベイクでは Unity 側が CombinedDirectional になり DIRLIGHTMAP_COMBINED も立つ。
                // 方向マップの意味が Unity 標準とは別物なので、_MONOSH_ON を先に判定して
                // DecodeDirectionalLightmap を通さないこと。
                #if defined(_MONOSH_ON)
                    half3 monoDiff, monoSpec;
                    dhk_MonoSH(bakedColor, data.lightmapUV.xy, normalWorld, data.worldViewDir, smoothness, monoDiff, monoSpec);
                    o_gi.indirect.diffuse += monoDiff;
                    // ベイクスペキュラは環境反射と同じ枠に載せる（後段でフレネルが掛かる）。
                    // 加算パスでの二重計上を避けるため base パスのみ。
                    #if !defined(UNITY_PASS_FORWARDADD)
                        o_gi.indirect.specular += monoSpec;
                    #endif

                    #if defined(LIGHTMAP_SHADOW_MIXING) && !defined(SHADOWS_SHADOWMASK) && defined(SHADOWS_SCREEN)
                        ResetUnityLight(o_gi.light);
                        o_gi.indirect.diffuse = SubtractMainLightWithRealtimeAttenuationFromLightmap(o_gi.indirect.diffuse, data.atten, bakedColorTex, normalWorld);
                    #endif
                #elif defined(DIRLIGHTMAP_COMBINED)
                    fixed4 bakedDirTex = UNITY_SAMPLE_TEX2D_SAMPLER(unity_LightmapInd, unity_Lightmap, data.lightmapUV.xy);
                    o_gi.indirect.diffuse += DecodeDirectionalLightmap(bakedColor, bakedDirTex, normalWorld);

                    #if defined(LIGHTMAP_SHADOW_MIXING) && !defined(SHADOWS_SHADOWMASK) && defined(SHADOWS_SCREEN)
                        ResetUnityLight(o_gi.light);
                        o_gi.indirect.diffuse = SubtractMainLightWithRealtimeAttenuationFromLightmap(o_gi.indirect.diffuse, data.atten, bakedColorTex, normalWorld);
                    #endif
                #else // 非方向ライトマップ
                    o_gi.indirect.diffuse += bakedColor;

                    #if defined(LIGHTMAP_SHADOW_MIXING) && !defined(SHADOWS_SHADOWMASK) && defined(SHADOWS_SCREEN)
                        ResetUnityLight(o_gi.light);
                        o_gi.indirect.diffuse = SubtractMainLightWithRealtimeAttenuationFromLightmap(o_gi.indirect.diffuse, data.atten, bakedColorTex, normalWorld);
                    #endif
                #endif
            #endif

            #ifdef DYNAMICLIGHTMAP_ON
                // リアルタイム GI（Enlighten）。低解像度ではないので通常サンプリングで十分。
                fixed4 realtimeColorTex = UNITY_SAMPLE_TEX2D(unity_DynamicLightmap, data.lightmapUV.zw);
                half3 realtimeColor = DecodeRealtimeLightmap(realtimeColorTex);

                #ifdef DIRLIGHTMAP_COMBINED
                    half4 realtimeDirTex = UNITY_SAMPLE_TEX2D_SAMPLER(unity_DynamicDirectionality, unity_DynamicLightmap, data.lightmapUV.zw);
                    o_gi.indirect.diffuse += DecodeDirectionalLightmap(realtimeColor, realtimeDirTex, normalWorld);
                #else
                    o_gi.indirect.diffuse += realtimeColor;
                #endif
            #endif

            // -----------------------------------------------------------------
            //  VRC Light Volumes（拡散のみ）
            //
            //  ・ライトマップがあるとき: ベイクと同じ光を二重に積まないよう、
            //    加算ボリューム（LightVolumeAdditiveSH）だけを足す。
            //  ・ライトマップが無いとき: Unity の SH を「置換」する。足すと二重になる。
            //  ・ForwardAdd では走らせない（base パスで一度だけ）。
            //
            //  鏡面（LightVolumeSpecular）はここに入れない。あれは f0 を適用済みの
            //  最終的な反射色で、indirect.specular に入れると後段の Unity BRDF が
            //  もう一度フレネルを掛けてしまい金属が破綻する。
            // -----------------------------------------------------------------
            #if defined(DHK_LV_ACTIVE) && !defined(UNITY_PASS_FORWARDADD)
                UNITY_BRANCH
                if (_UseLightVolumes > 0.5h && LightVolumesEnabled() > 0.5)
                {
                    float3 lvPos = data.worldPos + normalWorld * _LightVolumeBias;
                    float3 lvL0, lvL1r, lvL1g, lvL1b;
                    #if defined(LIGHTMAP_ON)
                        LightVolumeAdditiveSH(lvPos, lvL0, lvL1r, lvL1g, lvL1b);
                        o_gi.indirect.diffuse += LightVolumeEvaluate(normalWorld, lvL0, lvL1r, lvL1g, lvL1b);
                    #else
                        LightVolumeSH(lvPos, lvL0, lvL1r, lvL1g, lvL1b);
                        o_gi.indirect.diffuse = LightVolumeEvaluate(normalWorld, lvL0, lvL1r, lvL1g, lvL1b);
                    #endif
                }
            #endif

            o_gi.indirect.diffuse *= occlusion;
            return o_gi;
        }

        inline UnityGI dhk_GlobalIllumination(UnityGIInput data, half occlusion, half3 normalWorld, half smoothness, Unity_GlossyEnvironmentData glossIn)
        {
            UnityGI o_gi = dhk_UnityGI_Base(data, occlusion, normalWorld, smoothness);
            // 反射（環境マップ）は base パスのみで加算。add パスでの二重加算を防ぐ。
            // MonoSH のベイクスペキュラが既に入っている場合があるので上書きせず加算する。
            #if !defined(UNITY_PASS_FORWARDADD)
                o_gi.indirect.specular += UnityGI_IndirectSpecular(data, occlusion, glossIn);
            #endif
            return o_gi;
        }

        // =====================================================================
        //  ライティングモデル "StandardBicubic"
        //  BRDF は Unity の LightingStandard をそのまま使用。GI だけ差し替える。
        // =====================================================================
        inline half4 LightingStandardBicubic(SurfaceOutputStandard s, half3 viewDir, UnityGI gi)
        {
            return LightingStandard(s, viewDir, gi);
        }

        inline void LightingStandardBicubic_GI(SurfaceOutputStandard s, UnityGIInput data, inout UnityGI gi)
        {
            Unity_GlossyEnvironmentData g = UnityGlossyEnvironmentSetup(
                s.Smoothness, data.worldViewDir, s.Normal,
                lerp(unity_ColorSpaceDielectricSpec.rgb, s.Albedo, s.Metallic));
            gi = dhk_GlobalIllumination(data, s.Occlusion, s.Normal, s.Smoothness, g);
        }

        // =====================================================================
        //  サーフェス
        // =====================================================================
        sampler2D _MainTex;
        sampler2D _MetallicGlossMap;
        sampler2D _BumpMap;
        sampler2D _OcclusionMap;
        sampler2D _EmissionMap;

        // 各テクスチャの Tiling/Offset。サーフェスシェーダーの uv_MainTex を使うと
        // 全テクスチャが _MainTex の ST で引かれてしまうため、生 UV を1本だけ渡して
        // ここの _ST を surf 側で個別に適用する。
        float4 _MainTex_ST;
        float4 _MetallicGlossMap_ST;
        float4 _BumpMap_ST;
        float4 _OcclusionMap_ST;
        float4 _EmissionMap_ST;

        fixed4 _Color;
        half4  _MetallicChannelMask;
        half4  _SmoothnessChannelMask;
        half4  _OcclusionChannelMask;
        half   _SmoothnessIsRoughness;
        half   _Cutoff;
        half   _Metallic;
        half   _Glossiness;
        half   _GlossMapScale;
        half   _BumpScale;
        half   _OcclusionStrength;
        fixed4 _EmissionColor;

        // 生の texcoord0 を1本だけ渡す。名前を uv_ で始めないのは、
        // サーフェスシェーダーが uv_ 始まりを「そのテクスチャの ST で変換済み」として
        // 特別扱いするため。ここでは未変換のまま受け取りたい。
        struct Input
        {
            float2 dhkUV;
        };

        void dhkVert(inout appdata_full v, out Input o)
        {
            UNITY_INITIALIZE_OUTPUT(Input, o);
            o.dhkUV = v.texcoord.xy;
        }

        void surf(Input IN, inout SurfaceOutputStandard o)
        {
            // LOD Cross-Fade のディザ clip は #pragma surface の dithercrossfade が
            // 全生成パスへ自動挿入するため、ここには書かない。

            fixed4 c = tex2D(_MainTex, TRANSFORM_TEX(IN.dhkUV, _MainTex)) * _Color;

            #if defined(_ALPHATEST_ON)
                clip(c.a - _Cutoff);
            #endif

            o.Albedo = c.rgb;
            o.Alpha  = c.a;

            // パックマップ由来の AO を使ったかどうか。使ったなら別の Occlusion マップは読まない。
            half packedAoActive = 0;

            #if defined(_METALLICGLOSSMAP)
                half4 mg = tex2D(_MetallicGlossMap, TRANSFORM_TEX(IN.dhkUV, _MetallicGlossMap));
                // チャンネルは one-hot マスクとの内積で選ぶ（キーワードを増やさないため）
                o.Metallic = dot(mg, _MetallicChannelMask);
                half smoothnessSample = dot(mg, _SmoothnessChannelMask);
                // ORM 系は Roughness で入っているので反転できるようにする
                smoothnessSample = lerp(smoothnessSample, 1.0h - smoothnessSample, saturate(_SmoothnessIsRoughness));
                o.Smoothness = smoothnessSample * _GlossMapScale;

                packedAoActive = saturate(dot(_OcclusionChannelMask, half4(1, 1, 1, 1)));
                if (packedAoActive > 0.5h)
                {
                    o.Occlusion = LerpOneTo(dot(mg, _OcclusionChannelMask), _OcclusionStrength);
                }
            #else
                o.Metallic   = _Metallic;
                o.Smoothness = _Glossiness;
            #endif

            #if defined(_NORMALMAP)
                o.Normal = UnpackScaleNormal(tex2D(_BumpMap, TRANSFORM_TEX(IN.dhkUV, _BumpMap)), _BumpScale);
            #endif

            #if defined(_OCCLUSIONMAP)
                // パックマップから AO を取っている場合は二重に読まない
                if (packedAoActive <= 0.5h)
                {
                    o.Occlusion = LerpOneTo(tex2D(_OcclusionMap, TRANSFORM_TEX(IN.dhkUV, _OcclusionMap)).g, _OcclusionStrength);
                }
            #endif

            #if defined(_EMISSION)
                o.Emission = tex2D(_EmissionMap, TRANSFORM_TEX(IN.dhkUV, _EmissionMap)).rgb * _EmissionColor.rgb;
            #endif
        }
        ENDCG
    }

    FallBack "Standard"
    CustomEditor "you5248.DhkShadersEditor.DhkStandardGUI"
}
