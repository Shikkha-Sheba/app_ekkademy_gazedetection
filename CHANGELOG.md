## 0.1.0

- Initial extraction into a standalone package from the in-app
  attentiveness-detection module.
- `AttentivenessConfig` reconstructed (was referenced by the source files
  but not included in the original handoff) — verify thresholds/grace
  periods match your original values.
- Prompt dialog rewritten with plain Material widgets and a new
  `AttentivenessDialogTheme` for restyling, removing the dependency on the
  host app's design system.
