using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using UnityEditor;
using UnityEngine;

namespace you5248.DhkShadersEditor
{
    /// <summary>
    /// 連携パッケージ（VRC Light Volumes / LTCGI）の有無を検出し、
    /// <c>Runtime/Shaders/dhkPackages.cginc</c> に define を書き出す。
    ///
    /// なぜこれが要るか:
    ///   シェーダーが相手の cginc を直に #include すると、その相手が入っていない
    ///   プロジェクトでコンパイルエラーになる。dhk は他プロジェクトへ配る前提なので
    ///   「入れた瞬間に壊れる」のは許容できない。Unity のシェーダーコンパイラには
    ///   __has_include が無いため、define を外から与える方式を採る。
    ///
    /// 安全策:
    ///   * 内容が変わったときだけ書く（毎回書くとリインポートが無限に回る）
    ///   * 書けなくても落ちない（読み取り専用の配置なら黙って諦める。
    ///     その場合は連携機能が無効になるだけで、シェーダー自体は動く）
    /// </summary>
    [InitializeOnLoad]
    internal static class DhkPackageDefines
    {
        private const string GeneratedPath =
            "Packages/com.you5248.dhk-shaders/Runtime/Shaders/dhkPackages.cginc";

        // 検出対象: (define 名, 相手の cginc パス)
        private static readonly string[,] Targets =
        {
            { "DHK_VRCLV_AVAILABLE", "Packages/red.sim.lightvolumes/Shaders/LightVolumes.cginc" },
            { "DHK_LTCGI_AVAILABLE", "Packages/at.pimaker.ltcgi/Shaders/LTCGI.cginc" },
        };

        static DhkPackageDefines()
        {
            // アセットインポート中に走らせない
            EditorApplication.delayCall += Refresh;
        }

        [MenuItem("Tools/you5248/dhk Shaders/連携パッケージを再検出")]
        internal static void Refresh()
        {
            s_lightVolumesV3 = null;   // 連携先が更新されていても拾えるよう判定をやり直す
            var body = new StringBuilder();
            for (int i = 0; i < Targets.GetLength(0); i++)
            {
                var define = Targets[i, 0];
                var probe = Targets[i, 1];
                if (Exists(probe)) body.Append("#define ").Append(define).Append(" 1\n");
            }

            // LV 3.x の内部関数（通常/加算/PLV の分解評価に使う）は 2.x や 3.0.0 の初期の
            // プレリリースには無いか形が違う。版番号ではなく、使う関数が実在するかで判定する
            if (LightVolumesV3Available)
                body.Append("#define DHK_VRCLV_V3 1\n");

            var content = BuildFile(body.ToString());

            string fullPath;
            try { fullPath = Path.GetFullPath(GeneratedPath); }
            catch { return; }   // パッケージが見つからない構成では何もしない

            // 内容が同じなら書かない。書くとリインポートが走り、それが再びこの処理を
            // 呼ぶ形になって無限ループになりうる。
            try
            {
                if (File.Exists(fullPath) && File.ReadAllText(fullPath) == content) return;
            }
            catch { return; }

            try
            {
                File.WriteAllText(fullPath, content);
                AssetDatabase.ImportAsset(GeneratedPath, ImportAssetOptions.ForceUpdate);
                Debug.Log("[dhk Shaders] 連携パッケージの検出結果を更新しました: " +
                          (body.Length == 0 ? "（連携先なし）" : body.ToString().Replace("\n", " ").Trim()));
            }
            catch (IOException)
            {
                // 読み取り専用の配置。連携機能が無効になるだけで、シェーダーは動く。
            }
            catch (System.UnauthorizedAccessException)
            {
            }
        }

        internal static bool Exists(string assetPath)
        {
            try { return File.Exists(Path.GetFullPath(assetPath)); }
            catch { return false; }
        }

        /// <summary>ShaderGUI から「LV 連携が使えるか」を問い合わせるための入口。</summary>
        internal static bool LightVolumesAvailable
        {
            get { return Exists(Targets[0, 1]); }
        }

        // DHK_VRCLV_V3 の経路が呼ぶ LV の内部関数。3つとも同じ形で実在するときだけ使う
        private static readonly string[] LightVolumesV3Signatures =
        {
            @"void\s+LV_LightVolumeRegularSH\s*\(\s*float3\s+worldPos\s*,\s*inout\s+float3\s+L0",
            @"void\s+LV_LightVolumeAdditiveSH\s*\(\s*float3\s+worldPos\s*,\s*inout\s+float3\s+L0\s*,\s*inout\s+float3\s+L1r\s*,\s*inout\s+float3\s+L1g\s*,\s*inout\s+float3\s+L1b\s*\)",
            @"void\s+LV_PointLightVolumeSH\s*\(\s*float3\s+worldPos\s*,\s*float3\s+worldNormal\s*,\s*float\s+pointLightShading\s*,",
        };

        // ShaderGUI が再描画のたびに問い合わせるので、判定結果を覚えておく
        // （ドメインの再読み込みと Refresh でやり直す）
        private static bool? s_lightVolumesV3;

        /// <summary>
        /// LV 3.x の分解評価（影マスク・PLV の法線シェーディング）が使えるか。
        /// 読めなければ false（＝2.x と同じ公開 API の経路。LV 3.x の上でもコンパイルできる安全側）。
        /// </summary>
        internal static bool LightVolumesV3Available
        {
            get
            {
                if (!s_lightVolumesV3.HasValue) s_lightVolumesV3 = DetectLightVolumesV3();
                return s_lightVolumesV3.Value;
            }
        }

        private static bool DetectLightVolumesV3()
        {
            if (!LightVolumesAvailable) return false;
            try
            {
                var src = File.ReadAllText(Path.GetFullPath(Targets[0, 1]));
                foreach (var signature in LightVolumesV3Signatures)
                    if (!Regex.IsMatch(src, signature)) return false;
                return true;
            }
            catch
            {
                return false;
            }
        }

        private static string BuildFile(string defines)
        {
            return
"// -----------------------------------------------------------------------------\n" +
"//  dhk Shaders — 連携パッケージの検出結果（自動生成。手で編集しないこと）\n" +
"//\n" +
"//  you5248.DhkShadersEditor.DhkPackageDefines がプロジェクトを見て書き出す。\n" +
"//  出荷時は何も define していない状態で、連携先が入っていないプロジェクトでも\n" +
"//  シェーダーが必ずコンパイルできるようにしてある。\n" +
"//  パッケージを更新すると出荷時の内容に戻るが、次のエディタ起動で再生成される。\n" +
"//  手動で走らせたいときは Tools > you5248 > dhk Shaders > 連携パッケージを再検出。\n" +
"// -----------------------------------------------------------------------------\n" +
"#ifndef DHK_PACKAGES_INCLUDED\n" +
"#define DHK_PACKAGES_INCLUDED\n" +
"\n" +
// 連携先が無いときは出荷時のスタブとバイト単位で一致させる（一致しないと導入直後に必ず書き換えが走る）
(defines.Length == 0 ? "" : defines + "\n") +
"#endif\n";
        }
    }
}
