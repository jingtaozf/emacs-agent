# No Backward Compatibility Unless Explicitly Requested

Do not add backward compatibility shims, defalias wrappers, re-exports,
or migration code unless the user explicitly asks for it.

When refactoring or replacing functionality:
- Delete the old code entirely
- Update all callers to use the new API
- Do not leave "compatibility" wrappers behind
