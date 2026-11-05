;;; gui-scroll-modal.el --- Actual page keys and modal scroll targets -*- lexical-binding: t; -*-
(require 'chromel)
(setq chromel-data-directory (file-name-as-directory (getenv "CHROMEL_TEST_PROFILE")))
(defvar chromel-test--source nil)
(defvar chromel-test--busy nil)
(defvar chromel-test--phase 'loading)
(defvar chromel-test--deadline (+ (float-time) 40))
(defun chromel-test--assert (value text) (unless value (error "%s" text)))
(defun chromel-test--js (expression) (chromel--eval (concat "JSON.stringify(" expression ")")))
(defun chromel-test--until (expression description)
  (let ((deadline (+ (float-time) 4)) done)
    (while (and (not done) (< (float-time) deadline))
      (setq done (eq t (chromel-test--js expression)))
      (unless done (accept-process-output nil 0.01)))
    (chromel-test--assert done description)))
(defun chromel-test--finish (success description)
  (with-temp-file (getenv "CHROMEL_TEST_RESULT")
    (insert (if success "PASS: " "FAIL: ") description "\n"))
  (kill-emacs (if success 0 1)))
(defun chromel-test--click (selector)
  (let ((point (chromel-test--js
                (format "(()=>{const r=document.querySelector(%s).getBoundingClientRect();return {x:r.left+r.width/2,y:r.top+Math.min(12,r.height/2),newBuffer:false}})()"
                        (chromel--json selector)))))
    (chromel-focus)
    (chromel--command "click" (chromel--json point))))
(defun chromel-test--exercise ()
  (chromel-test--assert (eq t (chromel-test--js "Boolean(window.__emacsChromelScroller)"))
                    "Tracking was not installed before the first user interaction")
  ;; A non-focusable div clicked BEFORE the first scroll must be remembered.
  (chromel-test--click "#panel p")
  (chromel--command "test-key" "j")
  (chromel-test--until "document.getElementById('panel').scrollTop===60 && scrollY===0"
                   "First click/plain j did not scroll the nonfocusable panel")
  (chromel--command "test-key" "k")
  (chromel-test--until "document.getElementById('panel').scrollTop===0" "Actual k did not scroll up")
  ;; Open a modal while focus initially stays on its close button.  The scroll
  ;; container is a sibling, and the long outer body is locked.
  (chromel-test--click "#open-native")
  (chromel-test--until "document.getElementById('native').open" "Native modal did not open")
  (chromel--command "test-key-down" "j")
  (chromel-test--until "document.getElementById('native-scroll').scrollTop>150 && scrollY===0"
                   "Held j escaped the modal or stopped after one step")
  (chromel--command "test-key-up" "j")
  (accept-process-output nil 0.1)
  (let ((position (chromel-test--js "document.getElementById('native-scroll').scrollTop")))
    (accept-process-output nil 0.15)
    (chromel-test--assert (= position (chromel-test--js "document.getElementById('native-scroll').scrollTop"))
                     "Modal kept scrolling after keyup"))
  (let ((chromel-scroll-duration 0)) (chromel-scroll-to-top))
  (chromel-test--until "document.getElementById('native-scroll').scrollTop===0" "Modal reset failed")
  (chromel--command "test-key" "j")
  (chromel-test--until "document.getElementById('native-scroll').scrollTop===60 && scrollY===0"
                   "Native modal scroll was lost or moved the background")
  (let ((chromel-scroll-duration 0))
    (chromel-scroll-half-page-down)
    (chromel-test--until "document.getElementById('native-scroll').scrollTop===140 && scrollY===0"
                     "Half-page escaped the modal or used outer viewport height")
    (chromel-scroll-to-bottom)
    (chromel-test--until "document.getElementById('native-scroll').scrollTop===740 && scrollY===0"
                     "Bottom escaped the modal")
    (chromel-scroll-to-top)
    (chromel-test--until "document.getElementById('native-scroll').scrollTop===0 && scrollY===0"
                     "Top escaped the modal")
    (chromel-scroll-down)
    (chromel-test--until "document.getElementById('native-scroll').scrollTop===60" "Modal scroll reset failed"))
  (chromel-test--click "#text")
  (chromel-test--until "document.activeElement.id==='text'" "Input did not receive focus")
  (chromel--command "test-key" "j")
  (chromel--command "test-key" "k")
  (chromel-test--until "document.getElementById('text').value==='jk' && document.getElementById('native-scroll').scrollTop===60"
                   "Page scrolling stole letters from a text input")
  (chromel-test--click "#editable")
  (chromel-test--until "document.activeElement.id==='editable'" "Editor did not receive focus")
  (chromel--command "test-key" "j")
  (chromel-test--until "document.getElementById('editable').textContent.includes('j') && document.getElementById('native-scroll').scrollTop===60"
                   "Page scrolling stole letters from contenteditable")
  ;; Select controls have typeahead even though CEF may not call them editable.
  (chromel-test--js "(document.getElementById('select').focus(),true)")
  (chromel-test--until "document.activeElement.id==='select'" "Select did not focus")
  (accept-process-output nil 0.05)
  (chromel--command "test-key" "k")
  (chromel-test--until "document.getElementById('select').selectedIndex===1 && document.getElementById('native-scroll').scrollTop===60"
                   "Select typeahead was intercepted as a scroll key")
  (chromel-test--click "#close-native")
  (chromel-test--until "!document.getElementById('native').open" "Native modal did not close")
  ;; ARIA overlay does not auto-focus; the last activated node is underneath it.
  (chromel-test--click "#open-overlay")
  (chromel-test--until "!document.getElementById('overlay').hidden" "ARIA overlay did not open")
  (chromel--command "test-key" "j")
  (chromel-test--until "document.getElementById('overlay-scroll').scrollTop===60 && scrollY===0"
                   "ARIA overlay did not replace the stale background target")
  (chromel-test--click "#close-overlay")
  (chromel-test--until "document.getElementById('overlay').hidden" "ARIA overlay did not close")
  (chromel--command "test-key" "j")
  (chromel-test--until "scrollY===60" "Scrolling stayed trapped after the overlay closed")
  (chromel-test--assert (eq t (plist-get (json-parse-string (chromel--native-inspect chromel--id) :object-type 'plist) :focused))
                    "Actual page key scrolling unexpectedly released page focus"))
(defun chromel-test--step ()
  (unless chromel-test--busy
    (let ((chromel-test--busy t))
      (with-current-buffer (if (buffer-live-p chromel-test--source) chromel-test--source (current-buffer))
        (condition-case err
            (progn
              (when (> (float-time) chromel-test--deadline) (error "Modal key test timed out"))
              (pcase chromel-test--phase
                ('loading
                 (when (equal chromel--title "scroll-modal-ready")
                   (switch-to-buffer chromel-test--source)
                   (delete-other-windows)
                   (chromel--sync)
                   (chromel-test--exercise)
                   (kill-buffer chromel-test--source)
                   (setq chromel-test--phase 'closing)))
                ('closing
                 (when (string-match-p "Browsers including DevTools: 0" (chromel--native-info))
                   (chromel-test--finish t "Actual Cocoa j/k: first-click panel, native/ARIA modals over locked long pages, text/editor/select input, close-and-return")))))
          (error (chromel-test--finish nil (error-message-string err))))))))
(run-at-time 1 nil
             (lambda ()
               (condition-case err
                   (progn
                     (set-frame-size nil 1100 750 t)
                     (setq chromel-test--source (chromel (getenv "CHROMEL_TEST_URL")))
                     (run-at-time 0.2 0.2 #'chromel-test--step))
                 (error (chromel-test--finish nil (error-message-string err))))))
