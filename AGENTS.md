# AGENTS.md

## Code Style

- When using the Edit tool, do NOT reformat surrounding context. Only change the exact lines that need changing. Preserve the original formatting, quoting style (single vs double quotes), line breaks, and indentation of all unchanged code.
- Blender's Python files use single quotes for string literals in many places. Match the existing style in each file.
- Do not run formatters (black, ruff, etc.) on files you edit. Only apply the minimal diff needed for your change.
