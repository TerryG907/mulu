# tools/adversarial

对抗评审用过的脚本。这里只收生成器和驱动脚本；它们生成的 PDF、结果和日志不进 git（见仓库根目录的 `.gitignore`）。

| 目录 | 内容 |
|---|---|
| `spec-review/` | 按 PDF 规范逐条挑刺的手工 PDF（`make_cases*.py`） |
| `hostile-inputs/` | 恶意或畸形的 PDF：溢出、环、解压炸弹等（`make_hostile*.py`） |
| `producer-matrix/` | 用多种 PDF 生成器做样本，再用多种阅读器交叉检查（`run.sh`） |
| `week1-messy/` | 38 个「乱目录」扫描样例（`cases.py` 是文字内容，`make_cases.py` 渲染，`run_cases.py` 评分） |
| `week1-noregress/` | 扫描流水线的不退步和安全检查（`run.sh`、`gen_all.sh`、`gen_vector.py`、`gen_zerobox.py`） |

- 前三组评审发现的问题，每个都已经复制成一个复现样例，放在 `Fixtures/regression/`（已提交），`tools/run_all.sh` 每次都会跑。`tools/fixtures/make_regression.py` 只在重建那个目录时才需要这里生成的文件。
- `week1-messy/` 和 `week1-noregress/` 的输入由 `tools/eval/week1_regress.py`（`tools/run_all.sh --books` 会调用）在缺失时自动生成。第一次运行需要几分钟。

---

Scripts from the adversarial reviews. Only the generators and drivers are tracked; the PDFs, results and logs they produce are ignored by git. Every finding from the first three reviews has a committed reproducer in `Fixtures/regression/`, which `tools/run_all.sh` checks on every run. The `week1-*` inputs are regenerated on demand by `tools/eval/week1_regress.py` (called by `tools/run_all.sh --books`).
