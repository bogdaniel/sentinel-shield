/*
 * Sentinel Shield — dependency-cruiser ruleset: DDD bounded contexts (Node/TypeScript).
 *
 * Template only. Adapt to your namespaces/folders. Do not enable as blocking until observed clean.
 *
 * This is an EXAMPLE. The engine never auto-installs it and never overwrites project-owned
 * files — copy it to .dependency-cruiser.js (or point
 * architecture.tools.dependency_cruiser.config at it) yourself.
 *
 * Layout assumed:
 *   src/contexts/<context>/public/    published surface — other contexts MAY import this
 *   src/contexts/<context>/internal/  private model — only its own context may import it
 *   src/shared/                       context-agnostic primitives — anyone may import
 *
 * The cross-context rules use a back-reference so they work for ANY context name without
 * listing contexts one by one: $1 in `to.path` is the context captured in `from.path`.
 */

module.exports = {
  forbidden: [
    {
      name: 'no-cross-context-internals',
      severity: 'error',
      comment:
        "A context's internals are private. Import the other context's public/ surface " +
        '(or react to its published events) instead.',
      from: { path: '^src/contexts/([^/]+)/' },
      to: {
        path: '^src/contexts/([^/]+)/internal/',
        pathNot: '^src/contexts/$1/internal/',
      },
    },
    {
      name: 'public-not-to-other-contexts',
      severity: 'error',
      comment:
        "A context's public surface must be self-contained: it may use its own context and " +
        'src/shared, never another context.',
      from: { path: '^src/contexts/([^/]+)/public/' },
      to: {
        path: '^src/contexts/([^/]+)/',
        pathNot: '^src/contexts/$1/',
      },
    },
    {
      name: 'shared-not-to-contexts',
      severity: 'error',
      comment:
        'src/shared is context-agnostic; depending on a context inverts the dependency and ' +
        'couples every context together.',
      from: { path: '^src/shared' },
      to: { path: '^src/contexts/' },
    },
    {
      name: 'no-circular',
      severity: 'error',
      comment: 'Circular dependencies make context boundaries unenforceable.',
      from: {},
      to: { circular: true },
    },
  ],

  options: {
    doNotFollow: { path: 'node_modules' },
    tsPreCompilationDeps: true,
    exclude: { path: '\\.(test|spec)\\.(js|ts|tsx)$' },
  },
};
