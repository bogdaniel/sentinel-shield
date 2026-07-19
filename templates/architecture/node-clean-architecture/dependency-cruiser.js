/*
 * Sentinel Shield — dependency-cruiser ruleset: Clean Architecture (Node/TypeScript).
 *
 * Template only. Adapt to your namespaces/folders. Do not enable as blocking until observed clean.
 *
 * This is an EXAMPLE. The engine never auto-installs it and never overwrites project-owned
 * files — copy it to .dependency-cruiser.js (or point
 * architecture.tools.dependency_cruiser.config at it) yourself.
 *
 * Layout assumed: src/domain, src/application, src/infrastructure, src/presentation.
 * Dependencies point INWARD: presentation -> application -> domain; infrastructure
 * implements domain/application interfaces and is wired at the composition root.
 */

module.exports = {
  forbidden: [
    {
      name: 'domain-not-to-outer-layers',
      severity: 'error',
      comment:
        'Domain is the innermost layer: it must not depend on application, infrastructure ' +
        'or presentation.',
      from: { path: '^src/domain' },
      to: { path: '^src/(application|infrastructure|presentation)' },
    },
    {
      name: 'domain-not-to-frameworks',
      severity: 'error',
      comment:
        'Domain must stay framework-free: no HTTP servers, ORMs, or UI libraries. Extend the ' +
        'pathNot list with the packages your domain is genuinely allowed to use.',
      from: { path: '^src/domain' },
      to: {
        dependencyTypes: ['npm', 'npm-dev', 'npm-optional', 'npm-peer'],
        pathNot: '^node_modules/(date-fns|uuid|zod)(/|$)',
      },
    },
    {
      name: 'application-only-to-domain',
      severity: 'error',
      comment: 'Application orchestrates the domain; it may not reach into outer layers.',
      from: { path: '^src/application' },
      to: { path: '^src/(infrastructure|presentation)' },
    },
    {
      name: 'presentation-not-to-infrastructure',
      severity: 'error',
      comment:
        'Presentation talks to application use cases only; infrastructure is injected at the ' +
        'composition root.',
      from: { path: '^src/presentation' },
      to: { path: '^src/infrastructure' },
    },
    {
      name: 'no-circular',
      severity: 'error',
      comment: 'Circular dependencies make layering unenforceable and builds fragile.',
      from: {},
      to: { circular: true },
    },
    {
      name: 'no-orphans',
      severity: 'error',
      comment:
        'Orphan modules are unreachable code. Allow-list config/type-only entry points via ' +
        'the pathNot below.',
      from: {
        orphan: true,
        pathNot: [
          '(^|/)\\.[^/]+\\.(js|cjs|mjs|ts)$',
          '\\.d\\.ts$',
          '(^|/)tsconfig\\.json$',
          '(^|/)src/(main|index)\\.(js|ts)$',
        ],
      },
      to: {},
    },
  ],

  options: {
    doNotFollow: { path: 'node_modules' },
    tsPreCompilationDeps: true,
    exclude: { path: '\\.(test|spec)\\.(js|ts|tsx)$' },
  },
};
