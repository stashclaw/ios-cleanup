# Photo Quality Classifier — Training Guide

## Overview

`TrainPhotoQualityClassifier.swift` trains a 4-class image classifier using
Apple's Create ML framework. The trained model is used by `PhotoQualityAnalyzer`
in the iOS app to rank photos within duplicate groups. If the model is absent,
the app falls back to its existing heuristic pipeline.

Classes: **sharp**, **blurry**, **overexposed**, **underexposed**

---

## Datasets

Download these free, well-labelled academic datasets. Total download ~2 GB.

### KonIQ-10k *(primary quality signal — sharp vs blurry)*
- URL: http://database.mmsp-kn.de/koniq-10k-database.html
- 10,073 in-the-wild images with crowd-sourced MOS quality scores (0–100)
- Use images with **MOS ≥ 70** as `sharp/` examples (~3,000 images available)
- Use images with **MOS ≤ 30** as `blurry/` examples (~2,000 images available)
- Pick 500–600 from each bucket; balance the class sizes

### LIVE Image Quality Database *(distortion examples — blurry)*
- URL: https://live.ece.utexas.edu/research/quality/subjective.htm
- Download "LIVE Image Quality Assessment Database Release 2"
- ~800 distorted images with DMOS scores; blur and noise subsets are most useful
- Blur subset (blur DMOS > 50) → add to `blurry/` (~200 images)

### DIV2K *(high-resolution sharp training examples)*
- URL: https://data.vision.ee.ethz.ch/cvl/DIV2K/
- 800 ultra-sharp HR images; use all 800 as `sharp/` examples
- No quality labels needed — DIV2K is curated for sharpness

### Overexposed / Underexposed *(manually curate or use public sets)*
The academic datasets above don't have strong exposure labels, so these classes
need a bit more manual effort:

**Option A — Curate from KonIQ-10k by luminance:**
```python
from PIL import Image
import numpy as np, os, shutil

for fname in os.listdir("koniq10k/images/512x384"):
    img  = Image.open(f"koniq10k/images/512x384/{fname}").convert("L")
    mean = np.array(img).mean()
    if mean > 220:
        shutil.copy(...)  # → overexposed/
    elif mean < 30:
        shutil.copy(...)  # → underexposed/
```
Target: 200+ images per class.

**Option B — Use MIT FiveK dataset:**
- URL: https://data.csail.mit.edu/graphics/fivek/
- 5,000 RAW photos with expert retouching; original RAWs often over/underexposed
- Manually select 200 clearly over/underexposed originals

---

## Setup

### 1. Create the directory structure

```
CreateML/
  TrainingData/
    sharp/          ← 500–800 images  (KonIQ MOS≥70 + DIV2K)
    blurry/         ← 500–800 images  (KonIQ MOS≤30 + LIVE blur subset)
    overexposed/    ← 200–400 images
    underexposed/   ← 200–400 images
  TrainPhotoQualityClassifier.swift
  README.md
```

Images can be JPEG, PNG, HEIC, or TIFF. Resize to at most 1024px on the long
edge before training — Create ML will resize internally anyway, and smaller
inputs speed up data loading.

### 2. Run training

```bash
cd /path/to/ios-cleanup-main/CreateML
swift TrainPhotoQualityClassifier.swift
```

Requires macOS 12+ with Xcode installed (provides the CreateML framework).
Training takes **20–40 minutes on Apple Silicon** (M1/M2/M3).
On Intel it may take 60–90 minutes.

### 3. Monitor output

The script prints per-iteration accuracy. A healthy run looks like:

```
Iteration  5/25 — Training accuracy: 72.3%
Iteration 10/25 — Training accuracy: 81.4%
Iteration 20/25 — Training accuracy: 88.2%
Training complete:
  Training accuracy:   91.4%
  Validation accuracy: 87.6%
```

Target: **validation accuracy ≥ 85%**. If it stalls below 80%, add more data
to the weakest class or increase `maxIterations` to 50.

### 4. Install the model

```bash
cp PhotoQualityClassifier.mlmodel \
   ../iOSCleanup/Resources/PhotoQualityClassifier.mlmodel
```

In Xcode:
1. Drag `PhotoQualityClassifier.mlmodel` into the `Resources` group
2. Check **"Add to target: iOSCleanup"** in the file inspector
3. Build — Xcode compiles it to `PhotoQualityClassifier.mlmodelc`

The app's `PhotoQualityAnalyzer` detects the compiled model at runtime and
switches from heuristics to Core ML automatically. No code changes required.

---

## Expected Results

| Metric | Target |
|--------|--------|
| Validation accuracy | ≥ 85% |
| Inference time (iPhone 12+) | ~5 ms/image |
| Model size (`.mlmodelc` bundle) | 10–15 MB |

---

## Troubleshooting

**"Training failed: The folder does not exist"**
Ensure `TrainingData/` lives in the same directory as the script and contains
all four sub-folders.

**Validation accuracy < 75%**
- Check for mislabelled images — a single wrong folder can hurt significantly
- Add at least 200 images to any class with fewer than that
- Increase `maxIterations` to 50 in the script

**Out of memory during training**
Reduce the dataset to 400 images per class and retry.

**Model not picked up by the app**
Confirm the file is named exactly `PhotoQualityClassifier.mlmodel` and the
Xcode target membership box is checked. Clean build folder (⇧⌘K) then rebuild.

---

## How the app uses the model

`PhotoQualityAnalyzer` (in `iOSCleanup/Utilities/PhotoQualityAnalyzer.swift`)
loads the model lazily on first use via `VNCoreMLModel`. For each asset it:

1. Requests a 299×299 thumbnail from `PHImageManager`
2. Runs `VNCoreMLRequest` to get class probabilities
3. Computes a composite score: `P(sharp) − 0.7·P(blurry) − 0.5·P(over) − 0.5·P(under)`
4. Clamps to `[0, 1]` and caches by `localIdentifier`

If the model bundle is absent, steps 2–3 are replaced by the original
heuristic Laplacian + luminance + Vision face pipeline.
