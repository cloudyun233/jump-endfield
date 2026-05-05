import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

const devApiTarget = process.env.VITE_DEV_API_TARGET || 'http://127.0.0.1:20164';

export default defineConfig({
  base: './',
  plugins: [react()],
  build: {
    outDir: '../dist',
    emptyOutDir: true,
  },
  server: {
    proxy: {
      '/api': { target: devApiTarget, secure: false },
      '/media': { target: devApiTarget, secure: false },
      '/thumb': { target: devApiTarget, secure: false },
    },
  },
});
