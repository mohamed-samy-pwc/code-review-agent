// ESLint flat config (v9+)
import parser from '@typescript-eslint/parser';

export default [
  {
    files: ['src/**/*.ts'],
    languageOptions: { parser },
    rules: {}
  }
];
