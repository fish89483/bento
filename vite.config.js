import {defineConfig} from 'vite';

const repositoryName = process.env.GITHUB_REPOSITORY?.split('/').at(-1);
const isUserSite = repositoryName?.endsWith('.github.io');
const base = process.env.GITHUB_ACTIONS && repositoryName && !isUserSite
  ? `/${repositoryName}/`
  : '/';

export default defineConfig({
  base,
  server: {
    proxy: {
      '/api': 'http://127.0.0.1:8001'
    }
  },
  build: {
    outDir: 'dist',
    emptyOutDir: true,
    target: 'es2020'
  }
});
