// Only deliberately user/model-facing tool messages belong in this error.
// Never wrap raw provider, filesystem, or subprocess errors without sanitizing them.
export class ToolFailure extends Error {}
