/*
 * Sentinel Shield — ESLint flat config: React feature boundaries (JS/TS).
 *
 * Template only. Adapt to your namespaces/folders. Do not enable as blocking until observed clean.
 *
 * This is an EXAMPLE. The engine never auto-installs it and never overwrites project-owned
 * files — merge it into your own eslint.config.js (or point
 * architecture.tools.eslint_boundaries.config at a copy) yourself.
 *
 * Requires: eslint-plugin-boundaries, eslint-plugin-import.
 *
 * Element types and the allowed direction of imports:
 *   app      composition root / routing — may import feature, entity, shared
 *   feature  a vertical slice          — may import entity, shared (NEVER another feature)
 *   entity   domain models             — may import shared only
 *   shared   generic building blocks   — may import shared only (NEVER a feature)
 *
 * The runner counts only boundaries/*, import/no-restricted-paths and no-restricted-imports
 * as architecture violations, so keep these rules at "error".
 */

import boundaries from 'eslint-plugin-boundaries';
import importPlugin from 'eslint-plugin-import';

export default [
  {
    files: ['src/**/*.{js,jsx,ts,tsx}'],
    plugins: {
      boundaries,
      import: importPlugin,
    },
    settings: {
      'boundaries/elements': [
        { type: 'app', pattern: 'src/app/*' },
        { type: 'feature', pattern: 'src/features/*', capture: ['featureName'] },
        { type: 'entity', pattern: 'src/entities/*', capture: ['entityName'] },
        { type: 'shared', pattern: 'src/shared/*' },
      ],
      'boundaries/ignore': ['src/**/*.{test,spec}.{js,jsx,ts,tsx}'],
    },
    rules: {
      'boundaries/element-types': [
        'error',
        {
          default: 'disallow',
          rules: [
            { from: 'app', allow: ['feature', 'entity', 'shared'] },
            {
              from: 'feature',
              allow: [
                ['feature', { featureName: '${from.featureName}' }],
                'entity',
                'shared',
              ],
            },
            { from: 'entity', allow: ['shared'] },
            { from: 'shared', allow: ['shared'] },
          ],
        },
      ],
      'boundaries/no-private': ['error', { allowUncles: false }],

      // Zone example: the same boundary expressed via import paths, useful for folders that
      // are not modelled as boundaries elements.
      'import/no-restricted-paths': [
        'error',
        {
          zones: [
            {
              target: './src/shared',
              from: './src/features',
              message: 'shared must not import from features (it would invert the boundary).',
            },
            {
              target: './src/entities',
              from: './src/features',
              message: 'entities must not import from features.',
            },
            {
              target: './src/features',
              from: './src/app',
              message: 'features must not import the application shell.',
            },
          ],
        },
      ],
    },
  },
];
