# PhotoDuck ML Training

## Workflow

1. **Collect data** — Use the app. Every keep/delete/skip decision is recorded to the on-device SQLite store.

2. **Export from device** — The app writes training CSVs + the raw SQLite DB to the Documents directory. Pull via Finder, AirDrop, or Xcode device browser:
   ```
   ~/Documents/PhotoDuck-ML-Export/
   ├── keeper_ranking_training.csv
   ├── group_outcome_training.csv
   ├── training_stats.json
   └── photoduck-ml.sqlite
   ```

3. **Train on Mac** — Run the training script:
   ```bash
   swift TrainKeeperModel.swift /path/to/PhotoDuck-ML-Export
   ```
   Outputs:
   ```
   trained-models/
   ├── PhotoDuckKeeper.mlmodel
   └── PhotoDuckGroupAction.mlmodel
   ```

4. **Compile for iOS**:
   ```bash
   xcrun coremlcompiler compile trained-models/PhotoDuckKeeper.mlmodel .
   xcrun coremlcompiler compile trained-models/PhotoDuckGroupAction.mlmodel .
   ```

5. **Bundle** — Drop the `.mlmodelc` directories into the Xcode project.

## Models

### PhotoDuckKeeper
- **Task**: Predict which photo the user will keep as "best" in a similar group
- **Algorithm**: Boosted tree classifier
- **Features**: pixel dimensions, favorite/edited/screenshot flags, ranking score, similarity, aspect ratio, file size, bucket, group type, confidence
- **Labels**: `keeper`, `suggested_keeper`, `candidate`

### PhotoDuckGroupAction
- **Task**: Predict what action the user will take on a group (keep_best, deleted, skipped, etc.)
- **Algorithm**: Boosted tree classifier
- **Features**: bucket, group type, confidence, asset count, screenshot/favorite/edited counts, avg ranking score
- **Labels**: `keep_best_keeper`, `deleted`, `skipped`, `swipe_keep`, `swipe_delete`, etc.

## Storage Budget

- VNFeaturePrintObservation: 512 bytes per photo (128 floats × 4 bytes)
- Metadata per photo: ~200 bytes
- Feedback event: ~500 bytes
- 10GB budget → ~5M photos worth of embeddings. Typical library: 5K-50K photos = 5-50MB.
