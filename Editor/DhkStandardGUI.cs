using UnityEditor;
using UnityEngine;
using UnityEngine.Rendering;

namespace you5248.DhkShadersEditor
{
    /// <summary>
    /// dhk Standard / dhk Standard (Quest) 共用の ShaderGUI。
    ///
    /// このシェーダーは機能を [Toggle] キーワードで出し分けるため、既定のインスペクタだと
    /// 「OFF なのに子項目が並ぶ」「効かない Tiling/Offset が編集できてしまう」という
    /// 嘘の多い UI になる。ここではそれを畳み、あわせて C# でしか設定できない
    /// マテリアル状態（Emission の GI フラグ / Alpha Cutout の RenderType・Queue /
    /// キーワードの親子整合）を同期する。
    ///
    /// 設計上の約束:
    ///   * renderQueue は「Alpha Cutout の切り替えが起きた瞬間」だけ書く。
    ///     ValidateMaterial はマテリアル読込時にも呼ばれるので、そこで queue を書くと
    ///     ユーザーが Render Queue 欄で入れた値を毎回消してしまう。
    ///   * [HideInInspector] のプロパティは描かない。Quest 版は PC からのマテリアル
    ///     コピー互換のために未使用プロパティを持っており、それが出ると嘘になる。
    /// </summary>
    public class DhkStandardGUI : ShaderGUI
    {
        /// <summary>トグルと、それが有効なときだけ表示する子項目のまとまり。</summary>
        private struct Group
        {
            public string Header;            // 見出し（null なら出さない）
            public string Toggle;            // ON/OFF を決めるプロパティ名（null なら常に表示）
            public string[] Children;        // 子プロパティ名
            public string[] Textures;        // Tiling/Offset まで出すテクスチャプロパティ名
            public string HiddenWhenOn;      // このトグルが ON のとき子項目を隠す（値がマップに乗っ取られる欄）
            public bool QuestUnsupported;    // Quest 版では意味を持たないので出さない
        }

        private const string EmissionToggle = "_UseEmission";
        private const string AlphaTestToggle = "_AlphaTest";
        private const string MetallicMapToggle = "_UseMetallicMap";

        private static readonly string[] None = new string[0];

        private static readonly Group[] Groups =
        {
            new Group { Header = "Albedo", Toggle = null,
                        Children = new[] { "_Color" },
                        Textures = new[] { "_MainTex" } },

            new Group { Header = "Alpha Cutout", Toggle = AlphaTestToggle,
                        Children = new[] { "_Cutoff" },
                        Textures = None },

            // マップを使うときは _Metallic / _Glossiness は読まれない（PC は mg.r と mg.a）ので隠す
            new Group { Header = "Metallic / Smoothness", Toggle = null,
                        Children = new[] { "_Metallic", "_Glossiness" },
                        Textures = None,
                        HiddenWhenOn = MetallicMapToggle },

            new Group { Header = null, Toggle = MetallicMapToggle,
                        Children = new[] { "_GlossMapScale" },
                        Textures = new[] { "_MetallicGlossMap" },
                        QuestUnsupported = false },

            new Group { Header = "Normal Map", Toggle = "_UseNormalMap",
                        Children = new[] { "_BumpScale" },
                        Textures = new[] { "_BumpMap" } },

            new Group { Header = "Occlusion", Toggle = "_UseOcclusionMap",
                        Children = new[] { "_OcclusionStrength" },
                        Textures = new[] { "_OcclusionMap" } },

            new Group { Header = "Emission", Toggle = EmissionToggle,
                        Children = new[] { "_EmissionColor" },
                        Textures = new[] { "_EmissionMap" } },

            new Group { Header = "Bake Smoothing", Toggle = null,
                        Children = new[] { "_BicubicLightmap" },
                        Textures = None },

            new Group { Header = "MonoSH", Toggle = "_UseMonoSH",
                        Children = new[] { "_UseMonoSHSpec", "_MonoSHSpecMul", "_MonoSHNonlinear" },
                        Textures = None },

            new Group { Header = "Performance", Toggle = null,
                        Children = new[] { "_SpecularHighlightsOff", "_GlossyReflectionsOff" },
                        Textures = None },
        };

        // Quest 版では宣言はあるが読まれないプロパティ（PC からのコピー互換で残されている）
        private static readonly string[] QuestDeadProps = { "_Glossiness", "_GlossMapScale" };

        public override void OnGUI(MaterialEditor materialEditor, MaterialProperty[] props)
        {
            bool isQuest = IsQuest(materialEditor);

            // トグルの「切り替わった瞬間」を検出するために、描く前の値を控えておく
            // 複数選択で値が割れている（hasMixedValue）状態から一括で揃えられた場合、
            // 代表値が変わらないことがある。混在していたなら「変化した」とみなす。
            var alphaProp = Find(AlphaTestToggle, props);
            bool alphaBefore = alphaProp != null && alphaProp.floatValue > 0.5f;
            bool alphaMixedBefore = alphaProp != null && alphaProp.hasMixedValue;
            var emissionProp = Find(EmissionToggle, props);
            bool emissionBefore = emissionProp != null && emissionProp.floatValue > 0.5f;
            bool emissionMixedBefore = emissionProp != null && emissionProp.hasMixedValue;

            DrawCutoutQueueWarning(materialEditor, alphaProp);

            EditorGUI.BeginChangeCheck();

            foreach (var group in Groups)
            {
                var toggle = Find(group.Toggle, props);
                if (group.Toggle != null && toggle == null) continue;   // その構成には無い機能

                bool hiddenByOther = !string.IsNullOrEmpty(group.HiddenWhenOn) && IsOn(Find(group.HiddenWhenOn, props));
                if (hiddenByOther) continue;
                // パックマップから AO を取っているなら、別の Occlusion マップは読まれないので出さない
                if (group.Toggle == "_UseOcclusionMap" && PackedAoActive(props)) continue;

                var textures = Visible(group.Textures, props, isQuest);
                var children = Visible(group.Children, props, isQuest);
                if (toggle == null && textures.Length == 0 && children.Length == 0) continue;

                if (!string.IsNullOrEmpty(group.Header))
                {
                    EditorGUILayout.Space();
                    EditorGUILayout.LabelField(group.Header, EditorStyles.boldLabel);
                }

                if (toggle != null) materialEditor.ShaderProperty(toggle, toggle.displayName);

                // OFF のときは子項目を丸ごと隠す。複数選択で値が割れているときは触れるよう出す。
                bool expanded = toggle == null || toggle.floatValue > 0.5f || toggle.hasMixedValue;
                if (!expanded) continue;

                EditorGUI.indentLevel++;
                foreach (var tex in textures)
                {
                    materialEditor.TexturePropertySingleLine(new GUIContent(tex.displayName), tex);
                    // Tiling/Offset は「実際に効くテクスチャ」にだけ出す
                    materialEditor.TextureScaleOffsetProperty(tex);
                }
                foreach (var child in children)
                {
                    materialEditor.ShaderProperty(child, child.displayName);
                }
                // パックマップのチャンネル割り当てはテクスチャ直下に出す
                if (group.Toggle == MetallicMapToggle) DrawPackedMapControls(materialEditor, props);
                // Emission は GI への寄与方針もここで選ばせる（フラグだけ立てても足りないため）
                if (group.Toggle == EmissionToggle) materialEditor.LightmapEmissionProperty();
                EditorGUI.indentLevel--;
            }

            EditorGUILayout.Space();
            materialEditor.RenderQueueField();
            materialEditor.EnableInstancingField();
            materialEditor.DoubleSidedGIField();

            if (!EditorGUI.EndChangeCheck()) return;

            bool alphaChanged = alphaProp != null &&
                                (alphaMixedBefore || alphaBefore != (alphaProp.floatValue > 0.5f));
            bool emissionTurnedOn = emissionProp != null && emissionProp.floatValue > 0.5f &&
                                    (emissionMixedBefore || !emissionBefore);

            foreach (var obj in materialEditor.targets)
            {
                var mat = obj as Material;
                if (mat == null) continue;
                ValidateMaterial(mat);
                // Queue と RenderType は「Alpha Cutout が切り替わった瞬間」だけ触る。
                // それ以外で書くと Render Queue 欄の手入力を毎回潰してしまう。
                if (alphaChanged) ApplyAlphaTestRenderState(mat);
                // Emission を今 ON にしたときだけ、寄与先の既定を与える。
                if (emissionTurnedOn && IsOn(mat, EmissionToggle)) EnsureEmissionGiDefault(mat);
            }
        }

        /// <summary>
        /// トグルの値からキーワードとマテリアル状態を同期する。
        /// Unity はマテリアル読み込み時にもこれを呼ぶので、既存マテリアルの修復も兼ねる。
        /// ここでは renderQueue を書かない（ユーザーの上書きを壊すため）。
        /// </summary>
        public override void ValidateMaterial(Material material)
        {
            SyncKeyword(material, AlphaTestToggle, "_ALPHATEST_ON");
            SyncKeyword(material, MetallicMapToggle, "_METALLICGLOSSMAP");
            SyncKeyword(material, "_UseNormalMap", "_NORMALMAP");
            SyncKeyword(material, "_UseOcclusionMap", "_OCCLUSIONMAP");
            SyncKeyword(material, EmissionToggle, "_EMISSION");
            SyncKeyword(material, "_BicubicLightmap", "_BICUBICLIGHTMAP_ON");
            SyncKeyword(material, "_SpecularHighlightsOff", "_SPECULARHIGHLIGHTS_OFF");
            SyncKeyword(material, "_GlossyReflectionsOff", "_GLOSSYREFLECTIONS_OFF");

            // MonoSH のベイクスペキュラは親が OFF なら必ず OFF（死にバリアントを作らない）
            if (!IsOn(material, "_UseMonoSH") && material.HasProperty("_UseMonoSHSpec"))
                material.SetFloat("_UseMonoSHSpec", 0f);
            SyncKeyword(material, "_UseMonoSH", "_MONOSH_ON");
            SyncKeyword(material, "_UseMonoSHSpec", "_MONOSHSPEC_ON");

            // Emission: ここで触るのは EmissiveIsBlack のビットだけ。
            // 「None（見た目だけ光らせ、ベイクには出さない）」はワールド制作では普通の選択なので、
            // ロードのたびに BakedEmissive へ昇格させてはいけない（ユーザーの選択を潰す）。
            // 既定値としての BakedEmissive は、トグルが OFF→ON になった瞬間と
            // シェーダー載せ替え時にだけ与える（EnsureEmissionGiDefault）。
            if (material.HasProperty(EmissionToggle))
            {
                var flags = material.globalIlluminationFlags;
                if (IsOn(material, EmissionToggle)) flags &= ~MaterialGlobalIlluminationFlags.EmissiveIsBlack;
                else                                flags |= MaterialGlobalIlluminationFlags.EmissiveIsBlack;
                material.globalIlluminationFlags = flags;
            }
        }

        /// <summary>
        /// 他シェーダー（Standard など）から乗り換えた直後に、
        /// 割り当て済みのマップからトグルを推測して立てる。
        /// これをやらないと「テクスチャは入っているのに何も効かない」状態になる。
        /// </summary>
        public override void AssignNewShaderToMaterial(Material material, Shader oldShader, Shader newShader)
        {
            // 旧シェーダーの状態は base 呼び出しで失われうるので先に控える
            bool hadEmissionKeyword = material.IsKeywordEnabled("_EMISSION");
            bool hadAlphaTestKeyword = material.IsKeywordEnabled("_ALPHATEST_ON");
            bool fromDhk = oldShader != null && oldShader.name.Contains("dhk Standard");

            base.AssignNewShaderToMaterial(material, oldShader, newShader);

            if (!fromDhk)
            {
                TurnOnIfTextureAssigned(material, "_BumpMap", "_UseNormalMap");
                TurnOnIfTextureAssigned(material, "_MetallicGlossMap", MetallicMapToggle);
                TurnOnIfTextureAssigned(material, "_OcclusionMap", "_UseOcclusionMap");
                TurnOnIfTextureAssigned(material, "_EmissionMap", EmissionToggle);

                if (hadEmissionKeyword && material.HasProperty(EmissionToggle))
                    material.SetFloat(EmissionToggle, 1f);
                if (hadAlphaTestKeyword && material.HasProperty(AlphaTestToggle))
                    material.SetFloat(AlphaTestToggle, 1f);
            }

            ValidateMaterial(material);
            // シェーダーを載せ替えた瞬間は Queue も整えてよい（ここはユーザー入力の直後ではない）
            ApplyAlphaTestRenderState(material);
            // dhk 同士（PC↔Quest）の載せ替えでユーザーの None を Baked に昇格させない
            if (!fromDhk && IsOn(material, EmissionToggle)) EnsureEmissionGiDefault(material);
        }

        // ------------------------------------------------------------------
        //  パックマップ（1枚のテクスチャに Metallic / Occlusion / Smoothness を詰めたもの）
        // ------------------------------------------------------------------
        private static readonly string[] PresetLabels =
        {
            "Unity Standard  (Metallic=R, Smoothness=A)",
            "MOS / MAS  (Metallic=R, Occlusion=G, Smoothness=B)",
            "ORM (glTF)  (Occlusion=R, Roughness=G, Metallic=B)",
            "HDRP Mask  (Metallic=R, Occlusion=G, Smoothness=A)",
            "Custom",
        };

        private static readonly string[] ChannelLabels = { "R", "G", "B", "A", "使わない" };

        /// <summary>プリセット番号 → (metallic, smoothness, occlusion, roughness反転)</summary>
        private static void PresetLayout(int preset, out int m, out int sm, out int o, out bool rough)
        {
            switch (preset)
            {
                case 1:  m = 0; sm = 2; o = 1; rough = false; return;   // MOS / MAS
                case 2:  m = 2; sm = 1; o = 0; rough = true;  return;   // ORM
                case 3:  m = 0; sm = 3; o = 1; rough = false; return;   // HDRP Mask
                default: m = 0; sm = 3; o = 4; rough = false; return;   // Unity Standard
            }
        }

        private static Vector4 ChannelToMask(int channel)
        {
            switch (channel)
            {
                case 0:  return new Vector4(1, 0, 0, 0);
                case 1:  return new Vector4(0, 1, 0, 0);
                case 2:  return new Vector4(0, 0, 1, 0);
                case 3:  return new Vector4(0, 0, 0, 1);
                default: return Vector4.zero;   // 使わない
            }
        }

        private static int MaskToChannel(Vector4 mask)
        {
            if (mask.x > 0.5f) return 0;
            if (mask.y > 0.5f) return 1;
            if (mask.z > 0.5f) return 2;
            if (mask.w > 0.5f) return 3;
            return 4;
        }

        private static bool PackedAoActive(MaterialProperty[] props)
        {
            var useMap = Find(MetallicMapToggle, props);
            if (!IsOn(useMap)) return false;
            var occl = Find("_OcclusionChannelMask", props);
            if (occl == null) return false;
            return MaskToChannel(occl.vectorValue) != 4;
        }

        private static void DrawPackedMapControls(MaterialEditor materialEditor, MaterialProperty[] props)
        {
            var presetProp = Find("_PackedPreset", props);
            var mProp = Find("_MetallicChannelMask", props);
            var sProp = Find("_SmoothnessChannelMask", props);
            var oProp = Find("_OcclusionChannelMask", props);
            var roughProp = Find("_SmoothnessIsRoughness", props);
            if (presetProp == null || mProp == null || oProp == null) return;

            int preset = Mathf.Clamp(Mathf.RoundToInt(presetProp.floatValue), 0, PresetLabels.Length - 1);

            EditorGUI.BeginChangeCheck();
            preset = EditorGUILayout.Popup("チャンネル構成", preset, PresetLabels);
            bool presetChanged = EditorGUI.EndChangeCheck();
            if (presetChanged) presetProp.floatValue = preset;

            bool custom = preset == PresetLabels.Length - 1;

            if (presetChanged && !custom)
            {
                int m, sm, o; bool rough;
                PresetLayout(preset, out m, out sm, out o, out rough);
                mProp.vectorValue = ChannelToMask(m);
                if (sProp != null) sProp.vectorValue = ChannelToMask(sm);
                oProp.vectorValue = ChannelToMask(o);
                if (roughProp != null) roughProp.floatValue = rough ? 1f : 0f;
            }

            if (custom)
            {
                EditorGUI.indentLevel++;
                mProp.vectorValue = ChannelToMask(
                    EditorGUILayout.Popup("Metallic", MaskToChannel(mProp.vectorValue), ChannelLabels));
                if (sProp != null)
                    sProp.vectorValue = ChannelToMask(
                        EditorGUILayout.Popup("Smoothness", MaskToChannel(sProp.vectorValue), ChannelLabels));
                oProp.vectorValue = ChannelToMask(
                    EditorGUILayout.Popup("Occlusion", MaskToChannel(oProp.vectorValue), ChannelLabels));
                EditorGUI.indentLevel--;
            }

            if (roughProp != null)
            {
                materialEditor.ShaderProperty(roughProp,
                    new GUIContent("Roughness として解釈する (1 - 値)",
                                   "ORM など Smoothness ではなく Roughness で入っているマップ用"));
            }

            // マスクマップは必ずリニア。sRGB のままだと値が歪む。
            var texProp = Find("_MetallicGlossMap", props);
            if (texProp != null && texProp.textureValue != null)
            {
                var path = AssetDatabase.GetAssetPath(texProp.textureValue);
                var importer = string.IsNullOrEmpty(path) ? null : AssetImporter.GetAtPath(path) as TextureImporter;
                if (importer != null && importer.sRGBTexture)
                {
                    EditorGUILayout.HelpBox(
                        "このパックマップは sRGB としてインポートされています。" +
                        "マスク系のテクスチャは sRGB (Color Texture) を OFF にしてください。値がずれます。",
                        MessageType.Warning);
                }
            }
        }

        // ------------------------------------------------------------------
        /// <summary>
        /// Alpha Cutout が ON なのに Queue がシェーダー既定（Geometry）のままのマテリアルに、
        /// 警告と手動修正ボタンを出す。黙って書き換えないのは Render Queue の手入力を尊重するため。
        /// 旧版のシェーダーで作られたマテリアルがこの状態になりうる。
        /// </summary>
        private static void DrawCutoutQueueWarning(MaterialEditor materialEditor, MaterialProperty alphaProp)
        {
            if (alphaProp == null || alphaProp.floatValue <= 0.5f) return;

            bool anyStale = false;
            foreach (var obj in materialEditor.targets)
            {
                var mat = obj as Material;
                if (mat == null || mat.shader == null) continue;
                if (mat.renderQueue == mat.shader.renderQueue) { anyStale = true; break; }
            }
            if (!anyStale) return;

            EditorGUILayout.HelpBox(
                "Alpha Cutout が ON ですが、Render Queue がシェーダー既定 (Geometry) のままです。" +
                "切り抜きは AlphaTest (2450) が適切です。",
                MessageType.Warning);
            if (!GUILayout.Button("Render Queue を AlphaTest に直す")) return;

            foreach (var obj in materialEditor.targets)
            {
                var mat = obj as Material;
                if (mat == null || mat.shader == null) continue;
                // 独自の Queue を入れているマテリアルは巻き添えにしない
                if (mat.renderQueue != mat.shader.renderQueue) continue;
                ApplyAlphaTestRenderState(mat);
            }
        }

        /// <summary>Emission を有効化した直後、寄与先が未設定なら Baked を既定にする。</summary>
        private static void EnsureEmissionGiDefault(Material material)
        {
            if (material.globalIlluminationFlags == MaterialGlobalIlluminationFlags.None)
                material.globalIlluminationFlags = MaterialGlobalIlluminationFlags.BakedEmissive;
        }

        /// <summary>Alpha Cutout の有無に応じて RenderType タグと Queue を設定する。</summary>
        private static void ApplyAlphaTestRenderState(Material material)
        {
            if (!material.HasProperty(AlphaTestToggle)) return;

            if (IsOn(material, AlphaTestToggle))
            {
                material.SetOverrideTag("RenderType", "TransparentCutout");
                material.renderQueue = (int)RenderQueue.AlphaTest;
            }
            else
            {
                // 空文字で override を解除し、シェーダー側の宣言に戻す
                material.SetOverrideTag("RenderType", "");
                material.renderQueue = -1;
            }
        }

        private static bool IsQuest(MaterialEditor materialEditor)
        {
            var mat = materialEditor.target as Material;
            return mat != null && mat.shader != null && mat.shader.name.Contains("Quest");
        }

        private static MaterialProperty Find(string name, MaterialProperty[] props)
        {
            if (string.IsNullOrEmpty(name)) return null;
            return FindProperty(name, props, false);
        }

        /// <summary>描いてよいプロパティだけを抜き出す。</summary>
        private static MaterialProperty[] Visible(string[] names, MaterialProperty[] props, bool isQuest)
        {
            var list = new System.Collections.Generic.List<MaterialProperty>(names.Length);
            foreach (var n in names)
            {
                var p = Find(n, props);
                if (p == null) continue;
                // シェーダー側で [HideInInspector] が付いているものは出さない
                if ((p.flags & MaterialProperty.PropFlags.HideInInspector) != 0) continue;
                // Quest では宣言だけあって読まれないもの
                if (isQuest && System.Array.IndexOf(QuestDeadProps, n) >= 0) continue;
                list.Add(p);
            }
            return list.ToArray();
        }

        private static bool IsOn(MaterialProperty prop)
        {
            return prop != null && prop.floatValue > 0.5f;
        }

        private static bool IsOn(Material material, string prop)
        {
            return material.HasProperty(prop) && material.GetFloat(prop) > 0.5f;
        }

        private static void SyncKeyword(Material material, string prop, string keyword)
        {
            if (!material.HasProperty(prop)) return;
            if (IsOn(material, prop)) material.EnableKeyword(keyword);
            else material.DisableKeyword(keyword);
        }

        private static void TurnOnIfTextureAssigned(Material material, string texProp, string toggleProp)
        {
            if (!material.HasProperty(texProp) || !material.HasProperty(toggleProp)) return;
            if (material.GetTexture(texProp) != null) material.SetFloat(toggleProp, 1f);
        }
    }
}
