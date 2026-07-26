import React from 'react';
import { createRoot } from 'react-dom/client';
import '@fontsource/inter/400.css';
import '@fontsource/inter/500.css';
import '@fontsource/inter/600.css';
import '@pikoloo/darwin-ui/styles.css';
import './styles.css';
import App from './App.jsx';
import { ensureMockBridge } from './mock.js';

ensureMockBridge();

createRoot(document.getElementById('root')).render(<React.StrictMode><App /></React.StrictMode>);
