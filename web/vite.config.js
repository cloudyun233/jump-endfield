import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

const devApiTarget = process.env.VITE_DEV_API_TARGET || 'http://127.0.0.1:20164';

export default defineConfig({
  // 使用相对资源路径，方便把 dist 直接上传到任意目录或由脚本静态托管。
  base: './',
  plugins: [react()],
  build: {
    outDir: '../dist',
    emptyOutDir: true,
  },
  server: {
    proxy: {
      '/api': devApiTarget,
      '/media': devApiTarget,
      '/thumb': devApiTarget,
    },
  },
});
