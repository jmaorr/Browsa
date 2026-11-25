const f = document.createElement('iframe'); f.src = chrome.runtime.getURL('frame.html'); f.style.cssText = 'width:10px;height:10px'; document.body.appendChild(f);
