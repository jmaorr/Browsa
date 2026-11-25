import './browsa-shim.js';
import './background.js';
chrome.storage.local.set({ __browsaBG: 'background.js evaluated' });
