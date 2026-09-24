// dhkStandardCore.cginc — dhkStandard.shader の本体。
// ⚠ なぜ外出しか（消すな）: ビルド時の1パスのコンパイル指示は
// 「.shader ファイル本文 × キーワードの列挙数（≒ 2^shader_feature 本数 × 4）」のペイロードを
// ワーカーへ一括で送る（実測: 42.5KB × 8343 ≒ 354MB で UnityShaderCompiler ワーカーが即死）。
// include はワーカーがディスクから読むためペイロードに乗らない。
// よって .shader は Properties + pragma だけの薄皮にし、コードはここに置く。
// 列挙数の側も、機能トグルをなるべくユニフォーム分岐にして shader_feature を 7 本に抑えている。
// skip_variants や IPreprocessShaders のストリップはペイロードの組み立て後に効くので、
// この対策にはならない（コンパイルの総数が減るだけ）。削りたい軸はプロジェクト側で扱う。
// ※ #pragma は include 内では無視されるため .shader 側に残している
// ※ LOD Cross-Fade のディザ clip は .shader の #pragma surface の dithercrossfade が全生成パスへ挿入する

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
        // shader_feature を1本増やすごとにビルド時のペイロードが倍になるため（冒頭の注記参照）。
        // LV 側の LightVolumesEnabled() も [branch] 付きの実行時判定なので、
        // LV が無いワールドでは実質コストが乗らない。
        half _UseLightVolumes;
        half _LightVolumeBias;
        half _LVShadowMulStrength;
        half _LVShadowFloor;
        half _LVSpecularMul;
        // Point Light Volume を面の向きでどれだけ絞るか（LV 3.x のみ。0 = 向きを見ない＝1.4.x と同じ）
        half _LVPointLightShading;

        // LVスペキュラの受け渡し: GI段(worldPosを持つ)で計算し、BRDFの後で加算する。
        // gi.indirect.specular に入れると後段BRDFがフレネルを二重に掛けて金属が破綻するため
        // （LightVolumeSpecular は f0 適用済みの最終色を返す）、フラグメント内 static で運ぶ。
        // static はピクセルごとに 0 初期化され、ForwardAdd では LV 段が走らないので 0 のまま＝加算されない
        static half3 dhk_LvSpecularAccum = 0;

        // Specular（誇張と GSAA）。キーワードにせずユニフォーム分岐（バリアント抑制。LV と同じ理由）
        half _SpecBoost;
        half _UseGSAA;
        half _GsaaVariance;
        half _GsaaThreshold;

        // 旧キーワード4本のユニフォーム分岐化（ビルド時のペイロードを抑えるため。冒頭の注記参照）
        half _BicubicLightmap;
        half _SpecularHighlightsOff;
        half _GlossyReflectionsOff;

        // Rim Light（同じくユニフォーム分岐）
        half  _DhkUseRim;
        half4 _DhkRimColor;
        half  _DhkRimIntensity;
        half  _DhkRimPower;
        half  _DhkRimLightMask;

        // =====================================================================
        //  GSAA（Geometric Specular Anti-Aliasing）
        //  Kaplanyan らの法線分散フィルタリング（Tokuyoshi & Kaplanyan）と同じ系統の独自実装。
        //  法線がスクリーン1pxでどれだけ回るか（ddx/ddy）を粗さへ折り込み、
        //  遠距離やハイポリ細部で鏡面がピクセル単位に明滅するのを抑える。
        //  ※ ddx/ddy は呼び出し側で分岐の外で計算して渡すこと（勾配命令を
        //    フロー制御内に置くとコンパイラが落とす/平坦化する）
        // =====================================================================
        inline half dhk_GsaaSmoothness(half smoothness, float3 du, float3 dv)
        {
            float variance = _GsaaVariance * (dot(du, du) + dot(dv, dv));
            float kernel = min(2.0 * variance, _GsaaThreshold);
            float pr = SmoothnessToPerceptualRoughness(smoothness);
            pr = sqrt(saturate(pr * pr + kernel));
            return (half)(1.0 - pr);
        }

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

        // ユニフォーム分岐の中でもミップを正しく選べるよう、勾配を渡して読む。
        // 呼び出しは D3D11 に限っているので、それ以外では形だけの LOD0 読みにしておく
        #if defined(SHADER_API_D3D11)
            #define DHK_SAMPLE_LIGHTMAP_GRAD(uv, dx, dy) unity_Lightmap.SampleGrad(samplerunity_Lightmap, (uv), (dx), (dy))
        #else
            #define DHK_SAMPLE_LIGHTMAP_GRAD(uv, dx, dy) UNITY_SAMPLE_TEX2D_LOD(unity_Lightmap, (uv), 0)
        #endif

        // unity_Lightmap を texelSize=(w,h,1/w,1/h) でバイキュービック補間。dx/dy は元の uv の勾配
        half4 dhk_SampleLightmapBicubic(float2 uv, float4 texelSize, float2 dx, float2 dy)
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

            half4 rowA = gx0 * DHK_SAMPLE_LIGHTMAP_GRAD(uvAA, dx, dy) + gx1 * DHK_SAMPLE_LIGHTMAP_GRAD(uvBA, dx, dy);
            half4 rowB = gx0 * DHK_SAMPLE_LIGHTMAP_GRAD(uvAB, dx, dy) + gx1 * DHK_SAMPLE_LIGHTMAP_GRAD(uvBB, dx, dy);
            return gy0 * rowA + gy1 * rowB;
        }

        // ライトマップ参照を 1 箇所に集約。トグル OFF / 非 D3D11 時は通常のバイリニア。
        // ⚠ ユニフォーム分岐の中では暗黙の勾配を使うサンプルをコンパイラが拒否しうるので、
        //   勾配は分岐の外で取り、分岐の中は SampleGrad で読む（ミップの選び方は通常のサンプルと同じ）
        half4 dhk_SampleLightmap(float2 uv)
        {
            #if defined(SHADER_API_D3D11)
                float2 dx = ddx(uv);
                float2 dy = ddy(uv);
                half4 lightmap;
                UNITY_BRANCH
                if (_BicubicLightmap > 0.5h)
                {
                    float w, h;
                    unity_Lightmap.GetDimensions(w, h);
                    float4 texelSize = float4(w, h, 1.0 / w, 1.0 / h);
                    lightmap = dhk_SampleLightmapBicubic(uv, texelSize, dx, dy);
                }
                else
                {
                    lightmap = DHK_SAMPLE_LIGHTMAP_GRAD(uv, dx, dy);
                }
                return lightmap;
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
        half _UseMonoSHSpec;

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
            UNITY_BRANCH
            if (_UseMonoSHSpec > 0.5h)
            {
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
            }
        }
        #endif

        // =====================================================================
        //  GI（Standard の UnityGI_Base 相当をバイキュービックライトマップ版に置換）
        //  ※ベイクライトマップのサンプルだけを差し替え、その他（SH / 方向ライトマップ
        //    デコード / シャドウマスク合成 / 動的ライトマップ）は Standard と同一挙動。
        // =====================================================================
        inline UnityGI dhk_UnityGI_Base(UnityGIInput data, half occlusion, half3 normalWorld, half smoothness, half3 f0)
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
                        #if defined(DHK_VRCLV_V3)
                            LightVolumeAdditiveSH(lvPos, lvL0, lvL1r, lvL1g, lvL1b, 0, normalWorld, _LVPointLightShading);
                        #else
                            LightVolumeAdditiveSH(lvPos, lvL0, lvL1r, lvL1g, lvL1b);
                        #endif
                        o_gi.indirect.diffuse += LightVolumeEvaluate(normalWorld, lvL0, lvL1r, lvL1g, lvL1b);
                        UNITY_BRANCH
                        if (_LVSpecularMul > 0.001h)
                            dhk_LvSpecularAccum = (half3)LightVolumeSpecular((float3)f0, smoothness, normalWorld,
                                data.worldViewDir, lvL0, lvL1r, lvL1g, lvL1b) * (_LVSpecularMul * occlusion);
                    #elif !defined(DHK_VRCLV_V3)
                        // LV 2.x: 公開 API だけで評価する（影マスクは LV 3.x の分解評価が要るので無効）
                        LightVolumeSH(lvPos, lvL0, lvL1r, lvL1g, lvL1b);
                        o_gi.indirect.diffuse = LightVolumeEvaluate(normalWorld, lvL0, lvL1r, lvL1g, lvL1b);
                        UNITY_BRANCH
                        if (_LVSpecularMul > 0.001h)
                            dhk_LvSpecularAccum = (half3)LightVolumeSpecular((float3)f0, smoothness, normalWorld,
                                data.worldViewDir, lvL0, lvL1r, lvL1g, lvL1b) * (_LVSpecularMul * occlusion);
                    #else
                        // LV 3.x: 通常/加算/PLV を分解して評価し、**通常ボリュームだけ**に影マスクを掛ける。
                        // LightVolumeSH の合成順（regular → additive → PLV）をそのまま再現している。
                        // PLV は _LVPointLightShading で評価する（0 = 面の向きを見ない。LightVolumeSH の 5 引数版と同じ）
                        float3 R0 = 0, R1r = 0, R1g = 0, R1b = 0;
                        LV_LightVolumeRegularSH(lvPos, R0, R1r, R1g, R1b);
                        float3 lvRegular = LightVolumeEvaluate(normalWorld, R0, R1r, R1g, R1b);

                        float3 A0 = 0, A1r = 0, A1g = 0, A1b = 0;
                        LV_LightVolumeAdditiveSH(lvPos, A0, A1r, A1g, A1b);
                        LV_PointLightVolumeSH(lvPos, normalWorld, _LVPointLightShading, A0, A1r, A1g, A1b);
                        float3 lvUnshadowed = LightVolumeEvaluate(normalWorld, A0, A1r, A1g, A1b);

                        // [branch] は最適化ヒントに過ぎず平坦化されうるので、三項で strength=0 → mask=1 を保証
                        // （平坦化で「LVを丸ごと引き算」になる事故を実測で確認済み）
                        half lvMask = _LVShadowMulStrength > 0.001h
                            ? lerp(1.0h, lerp(_LVShadowFloor, 1.0h, (half)data.atten), _LVShadowMulStrength)
                            : 1.0h;
                        o_gi.indirect.diffuse = lvRegular * lvMask + lvUnshadowed;

                        // LVスペキュラ（0=OFF）。通常ボリュームは影マスク済みSHで、蛍/PLVは素通しで合成
                        UNITY_BRANCH
                        if (_LVSpecularMul > 0.001h)
                        {
                            float3 S0  = R0  * lvMask + A0;
                            float3 S1r = R1r * lvMask + A1r;
                            float3 S1g = R1g * lvMask + A1g;
                            float3 S1b = R1b * lvMask + A1b;
                            dhk_LvSpecularAccum = (half3)LightVolumeSpecular((float3)f0, smoothness, normalWorld,
                                data.worldViewDir, S0, S1r, S1g, S1b) * (_LVSpecularMul * occlusion);
                        }
                    #endif
                }
            #endif

            o_gi.indirect.diffuse *= occlusion;
            return o_gi;
        }

        inline UnityGI dhk_GlobalIllumination(UnityGIInput data, half occlusion, half3 normalWorld, half smoothness, half3 f0, Unity_GlossyEnvironmentData glossIn)
        {
            UnityGI o_gi = dhk_UnityGI_Base(data, occlusion, normalWorld, smoothness, f0);
            // 反射（環境マップ）は base パスのみで加算。add パスでの二重加算を防ぐ。
            // MonoSH のベイクスペキュラが既に入っている場合があるので上書きせず加算する。
            #if !defined(UNITY_PASS_FORWARDADD)
                // 旧 _GLOSSYREFLECTIONS_OFF のユニフォーム版（Standard同様フラット色へ退化）。
                // 三項にすると両側が評価されてキューブマップを読んでしまうので if にする
                UNITY_BRANCH
                if (_GlossyReflectionsOff > 0.5h)
                    o_gi.indirect.specular += unity_IndirectSpecColor.rgb * occlusion;
                else
                    o_gi.indirect.specular += UnityGI_IndirectSpecular(data, occlusion, glossIn);
            #endif
            return o_gi;
        }

        // =====================================================================
        //  ライティングモデル "StandardBicubic"
        //  BRDF は Unity の LightingStandard の本体を展開したもの（UnityPBSLighting.cginc と
        //  同一手順）。展開しているのは GSAA とスペキュラ強調の割り込み点を作るためで、
        //  _SpecBoost=1 / _UseGSAA=0（既定）なら LightingStandard と数学的に同値。
        // =====================================================================
        inline half4 LightingStandardBicubic(SurfaceOutputStandard s, half3 viewDir, UnityGI gi)
        {
            s.Normal = normalize(s.Normal);

            // 勾配はフロー制御の外で先に取る（dhk_GsaaSmoothness のコメント参照）
            float3 gsaaDu = ddx(s.Normal);
            float3 gsaaDv = ddy(s.Normal);
            UNITY_BRANCH
            if (_UseGSAA > 0.5h)
                s.Smoothness = dhk_GsaaSmoothness(s.Smoothness, gsaaDu, gsaaDv);

            half oneMinusReflectivity;
            half3 specColor;
            half3 diffColor = DiffuseAndSpecularFromMetallic(s.Albedo, s.Metallic, /*out*/ specColor, /*out*/ oneMinusReflectivity);

            // スペキュラ強調: F0 だけを持ち上げる。拡散(diffColor)と oneMinusReflectivity は
            // 触らない＝エネルギー保存を意図的に破って「艶だけ」誇張する
            specColor *= _SpecBoost;

            half outputAlpha;
            diffColor = PreMultiplyAlpha(diffColor, s.Alpha, oneMinusReflectivity, /*out*/ outputAlpha);

            half4 c;
            UNITY_BRANCH
            if (_SpecularHighlightsOff > 0.5h)
            {
                // 旧 _SPECULARHIGHLIGHTS_OFF のユニフォーム版。Standard と同じく直接光の鏡面だけを 0 にし、
                // 環境反射は残す。BRDF は「拡散項 + 直接光の鏡面項 + 環境反射項」の和で、拡散項は
                // specColor に依らないので、次の2回に分けて足すと Standard の結果と一致する
                //   1回目: specColor = 0・環境反射なし → 拡散項だけ
                //   2回目: 拡散色 0・直接光なし・環境拡散なし → 環境反射項だけ
                UnityIndirect diffuseOnly = gi.indirect;
                diffuseOnly.specular = 0;
                UnityLight noLight = gi.light;
                noLight.color = 0;
                UnityIndirect reflectionOnly = gi.indirect;
                reflectionOnly.diffuse = 0;
                c = UNITY_BRDF_PBS(diffColor, (half3)0, oneMinusReflectivity, s.Smoothness, s.Normal, viewDir, gi.light, diffuseOnly)
                  + UNITY_BRDF_PBS((half3)0, specColor, oneMinusReflectivity, s.Smoothness, s.Normal, viewDir, noLight, reflectionOnly);
            }
            else
            {
                c = UNITY_BRDF_PBS(diffColor, specColor, oneMinusReflectivity, s.Smoothness, s.Normal, viewDir, gi.light, gi.indirect);
                // LVスペキュラ（GI段で計算済みの最終色。base パスのみ値が入る）。ハイライトの一種なので
                // _SpecularHighlightsOff のときは足さない
                c.rgb += dhk_LvSpecularAccum;
            }

            // リムライト: 掠め角の縁を加算発光させる。base パスのみ（add パスで多重加算しない）。
            // _DhkRimLightMask=1 でメインライトの当たる側だけ光る（暗い側の縁が浮くのを抑える用）
            #if !defined(UNITY_PASS_FORWARDADD)
                UNITY_BRANCH
                if (_DhkUseRim > 0.5h)
                {
                    half rim = pow(1.0h - saturate(dot(s.Normal, viewDir)), _DhkRimPower);
                    half nl = saturate(dot(s.Normal, gi.light.dir));
                    half mask = lerp(1.0h, nl, _DhkRimLightMask);
                    c.rgb += _DhkRimColor.rgb * (_DhkRimIntensity * rim * mask);
                }
            #endif

            c.a = outputAlpha;
            return c;
        }

        inline void LightingStandardBicubic_GI(SurfaceOutputStandard s, UnityGIInput data, inout UnityGI gi)
        {
            // GI 側（環境反射のミップ選択・MonoSH ベイクスペキュラの粗さ）にも同じ GSAA を
            // 掛けて直接光側と粗さを一致させる
            float3 gsaaDu = ddx(s.Normal);
            float3 gsaaDv = ddy(s.Normal);
            UNITY_BRANCH
            if (_UseGSAA > 0.5h)
                s.Smoothness = dhk_GsaaSmoothness(s.Smoothness, gsaaDu, gsaaDv);

            half3 f0 = lerp(unity_ColorSpaceDielectricSpec.rgb, s.Albedo, s.Metallic);
            Unity_GlossyEnvironmentData g = UnityGlossyEnvironmentSetup(
                s.Smoothness, data.worldViewDir, s.Normal, f0);
            gi = dhk_GlobalIllumination(data, s.Occlusion, s.Normal, s.Smoothness, f0, g);
        }

        // =====================================================================
        //  サーフェス
        // =====================================================================
        sampler2D _MainTex;
        sampler2D _MetallicGlossMap;
        sampler2D _BumpMap;
        sampler2D _OcclusionMap;
        sampler2D _EmissionMap;
        #if defined(_DHKDETAIL_ON)
        // D3D11 のサンプラーは 16 個まで（LV 3.x の最悪の変種で 15 個使っている＝残り 1）。
        // サンプラーを足すときは、既存のサンプラーを _NOSAMPLER で共有すること。
        // 全マップ＋ライトマップ系の変種で溢れるので、ディテールの
        // 残り 4 枚は Detail Albedo のサンプラーを共有する（Wrap/Filter は Detail Albedo の設定に従う）。
        // ディテールが ON なら Detail Albedo は必ず読まれるので、このサンプラーは常に生きている
        UNITY_DECLARE_TEX2D(_DetailAlbedoMap);
        UNITY_DECLARE_TEX2D_NOSAMPLER(_DetailNormalMap);
        UNITY_DECLARE_TEX2D_NOSAMPLER(_DetailMetallicGlossMap);
        UNITY_DECLARE_TEX2D_NOSAMPLER(_DetailOcclusionMap);
        UNITY_DECLARE_TEX2D_NOSAMPLER(_DetailMask);
        // 各マップが自分の Tiling/Offset を持つ（Inspector に出ている欄がそのまま効く）
        float4 _DetailAlbedoMap_ST;
        float4 _DetailNormalMap_ST;
        float4 _DetailMetallicGlossMap_ST;
        float4 _DetailOcclusionMap_ST;
        float4 _DetailMask_ST;
        half _DetailAlbedoBlend;
        half _DetailAlbedoStrength;
        half _DetailNormalMapScale;
        half _DetailMSStrength;
        half _DetailOcclusionStrength;
        half _DetailMaskStrength;
        #endif

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

            #if defined(_DHKDETAIL_ON)
                // 各マップは自分の Tiling/Offset で引く（Inspector の各 Tiling 欄がそのまま効く）。
                // Unity Standard は全ディテールが Detail Albedo の ST を共有する点が違う
                half dhkDetailMask = lerp(1.0h,
                    UNITY_SAMPLE_TEX2D_SAMPLER(_DetailMask, _DetailAlbedoMap, TRANSFORM_TEX(IN.dhkUV, _DetailMask)).a, _DetailMaskStrength);

                // Albedo 合成: MulX2(Standard互換) / Multiply / Add / Overlay / Replace
                half3 dhkDetailAlbedo = UNITY_SAMPLE_TEX2D(_DetailAlbedoMap, TRANSFORM_TEX(IN.dhkUV, _DetailAlbedoMap)).rgb;
                half3 dhkBase = o.Albedo;
                half3 dhkBlended =
                    _DetailAlbedoBlend < 0.5h ? dhkBase * dhkDetailAlbedo * unity_ColorSpaceDouble.rgb :
                    _DetailAlbedoBlend < 1.5h ? dhkBase * dhkDetailAlbedo :
                    _DetailAlbedoBlend < 2.5h ? dhkBase + dhkDetailAlbedo :
                    _DetailAlbedoBlend < 3.5h ? lerp(2.0h * dhkBase * dhkDetailAlbedo,
                                                     1.0h - 2.0h * (1.0h - dhkBase) * (1.0h - dhkDetailAlbedo),
                                                     step(0.5h, dhkBase)) :
                                                dhkDetailAlbedo;
                o.Albedo = lerp(dhkBase, dhkBlended, dhkDetailMask * _DetailAlbedoStrength);
            #endif

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

            #if defined(_NORMALMAP) || defined(_DHKDETAIL_ON)
                half3 dhkNormal = half3(0, 0, 1);
                #if defined(_NORMALMAP)
                    dhkNormal = UnpackScaleNormal(tex2D(_BumpMap, TRANSFORM_TEX(IN.dhkUV, _BumpMap)), _BumpScale);
                #endif
                #if defined(_DHKDETAIL_ON)
                    half3 dhkDetailNormal = UnpackScaleNormal(
                        UNITY_SAMPLE_TEX2D_SAMPLER(_DetailNormalMap, _DetailAlbedoMap, TRANSFORM_TEX(IN.dhkUV, _DetailNormalMap)),
                        _DetailNormalMapScale * dhkDetailMask);
                    dhkNormal = BlendNormals(dhkNormal, dhkDetailNormal);
                #endif
                o.Normal = dhkNormal;
            #endif

            #if defined(_OCCLUSIONMAP)
                // パックマップから AO を取っている場合は二重に読まない
                if (packedAoActive <= 0.5h)
                {
                    o.Occlusion = LerpOneTo(tex2D(_OcclusionMap, TRANSFORM_TEX(IN.dhkUV, _OcclusionMap)).g, _OcclusionStrength);
                }
            #endif

            #if defined(_DHKDETAIL_ON)
                // Metallic / Smoothness / Occlusion はディテールを「乗算」で重ねる
                // （white=×1 が無効値。乗算なので値を上げる方向には効かない）
                half4 dhkDetailMg = UNITY_SAMPLE_TEX2D_SAMPLER(_DetailMetallicGlossMap, _DetailAlbedoMap, TRANSFORM_TEX(IN.dhkUV, _DetailMetallicGlossMap));
                half dhkMsW = _DetailMSStrength * dhkDetailMask;
                o.Metallic   = saturate(o.Metallic   * LerpOneTo(dhkDetailMg.r, dhkMsW));
                o.Smoothness = saturate(o.Smoothness * LerpOneTo(dhkDetailMg.a, dhkMsW));
                o.Occlusion *= LerpOneTo(UNITY_SAMPLE_TEX2D_SAMPLER(_DetailOcclusionMap, _DetailAlbedoMap, TRANSFORM_TEX(IN.dhkUV, _DetailOcclusionMap)).g,
                                         _DetailOcclusionStrength * dhkDetailMask);
            #endif

            #if defined(_EMISSION)
                o.Emission = tex2D(_EmissionMap, TRANSFORM_TEX(IN.dhkUV, _EmissionMap)).rgb * _EmissionColor.rgb;
            #endif
        }
        
