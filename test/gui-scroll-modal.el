;;; gui-scroll-modal.el --- Actual page keys and modal scroll targets -*- lexical-binding: t; -*-
(require 'web)
(setq web-data-directory (file-name-as-directory (getenv "WEB_TEST_PROFILE")))
(defvar web-test--source nil)
(defvar web-test--busy nil)
(defvar web-test--phase 'loading)
(defvar web-test--deadline (+ (float-time) 40))
(defun web-test--assert (value text) (unless value (error "%s" text)))
(defun web-test--js (expression) (web--eval (concat "JSON.stringify(" expression ")")))
(defun web-test--until (expression description)
  (let ((deadline (+ (float-time) 4)) done)
    (while (and (not done) (< (float-time) deadline))
      (setq done (eq t (web-test--js expression)))
      (unless done (accept-process-output nil 0.01)))
    (web-test--assert done description)))
(defun web-test--finish (success description)
  (with-temp-file (getenv "WEB_TEST_RESULT")
    (insert (if success "PASS: " "FAIL: ") description "\n"))
  (kill-emacs (if success 0 1)))
(defun web-test--click (selector)
  (let ((point (web-test--js
                (format "(()=>{const r=document.querySelector(%s).getBoundingClientRect();return {x:r.left+r.width/2,y:r.top+Math.min(12,r.height/2),newBuffer:false}})()"
                        (web--json selector)))))
    (web-focus)
    (web--command "click" (web--json point))))
(defun web-test--exercise ()
  (web-test--assert (eq t (web-test--js "Boolean(window.__emacsWebScroller)"))
                    "Tracking was not installed before the first user interaction")
  ;; A non-focusable div clicked BEFORE the first scroll must be remembered.
  (web-test--click "#panel p")
  (web--command "test-key" "j")
  (web-test--until "document.getElementById('panel').scrollTop===60 && scrollY===0"
                   "First click/plain j did not scroll the nonfocusable panel")
  (web--command "test-key" "k")
  (web-test--until "document.getElementById('panel').scrollTop===0" "Actual k did not scroll up")
  ;; Open a modal while focus initially stays on its close button.  The scroll
  ;; container is a sibling, and the long outer body is locked.
  (web-test--click "#open-native")
  (web-test--until "document.getElementById('native').open" "Native modal did not open")
  (web--command "test-key-down" "j")
  (web-test--until "document.getElementById('native-scroll').scrollTop>150 && scrollY===0"
                   "Held j escaped the modal or stopped after one step")
  (web--command "test-key-up" "j")
  (accept-process-output nil 0.1)
  (let ((position (web-test--js "document.getElementById('native-scroll').scrollTop")))
    (accept-process-output nil 0.15)
    (web-test--assert (= position (web-test--js "document.getElementById('native-scroll').scrollTop"))
                     "Modal kept scrolling after keyup"))
  (let ((web-scroll-duration 0)) (web-scroll-to-top))
  (web-test--until "document.getElementById('native-scroll').scrollTop===0" "Modal reset failed")
  (web--command "test-key" "j")
  (web-test--until "document.getElementById('native-scroll').scrollTop===60 && scrollY===0"
                   "Native modal scroll was lost or moved the background")
  (let ((web-scroll-duration 0))
    (web-scroll-half-page-down)
    (web-test--until "document.getElementById('native-scroll').scrollTop===140 && scrollY===0"
                     "Half-page escaped the modal or used outer viewport height")
    (web-scroll-to-bottom)
    (web-test--until "document.getElementById('native-scroll').scrollTop===740 && scrollY===0"
                     "Bottom escaped the modal")
    (web-scroll-to-top)
    (web-test--until "document.getElementById('native-scroll').scrollTop===0 && scrollY===0"
                     "Top escaped the modal")
    (web-scroll-down)
    (web-test--until "document.getElementById('native-scroll').scrollTop===60" "Modal scroll reset failed"))
  (web-test--click "#text")
  (web-test--until "document.activeElement.id==='text'" "Input did not receive focus")
  (web--command "test-key" "j")
  (web--command "test-key" "k")
  (web-test--until "document.getElementById('text').value==='jk' && document.getElementById('native-scroll').scrollTop===60"
                   "Page scrolling stole letters from a text input")
  (web-test--click "#editable")
  (web-test--until "document.activeElement.id==='editable'" "Editor did not receive focus")
  (web--command "test-key" "j")
  (web-test--until "document.getElementById('editable').textContent.includes('j') && document.getElementById('native-scroll').scrollTop===60"
                   "Page scrolling stole letters from contenteditable")
  ;; Select controls have typeahead even though CEF may not call them editable.
  (web-test--js "(document.getElementById('select').focus(),true)")
  (web-test--until "document.activeElement.id==='select'" "Select did not focus")
  (accept-process-output nil 0.05)
  (web--command "test-key" "k")
  (web-test--until "document.getElementById('select').selectedIndex===1 && document.getElementById('native-scroll').scrollTop===60"
                   "Select typeahead was intercepted as a scroll key")
  (web-test--click "#close-native")
  (web-test--until "!document.getElementById('native').open" "Native modal did not close")
  ;; ARIA overlay does not auto-focus; the last activated node is underneath it.
  (web-test--click "#open-overlay")
  (web-test--until "!document.getElementById('overlay').hidden" "ARIA overlay did not open")
  (web--command "test-key" "j")
  (web-test--until "document.getElementById('overlay-scroll').scrollTop===60 && scrollY===0"
                   "ARIA overlay did not replace the stale background target")
  (web-test--click "#close-overlay")
  (web-test--until "document.getElementById('overlay').hidden" "ARIA overlay did not close")
  (web--command "test-key" "j")
  (web-test--until "scrollY===60" "Scrolling stayed trapped after the overlay closed")
  (web-test--assert (eq t (plist-get (json-parse-string (web--native-inspect web--id) :object-type 'plist) :focused))
                    "Actual page key scrolling unexpectedly released page focus"))
(defun web-test--step ()
  (unless web-test--busy
    (let ((web-test--busy t))
      (with-current-buffer (if (buffer-live-p web-test--source) web-test--source (current-buffer))
        (condition-case err
            (progn
              (when (> (float-time) web-test--deadline) (error "Modal key test timed out"))
              (pcase web-test--phase
                ('loading
                 (when (equal web--title "scroll-modal-ready")
                   (switch-to-buffer web-test--source)
                   (delete-other-windows)
                   (web--sync)
                   (web-test--exercise)
                   (kill-buffer web-test--source)
                   (setq web-test--phase 'closing)))
                ('closing
                 (when (string-match-p "Browsers including DevTools: 0" (web--native-info))
                   (web-test--finish t "Actual Cocoa j/k: first-click panel, native/ARIA modals over locked long pages, text/editor/select input, close-and-return")))))
          (error (web-test--finish nil (error-message-string err))))))))
(run-at-time 1 nil
             (lambda ()
               (condition-case err
                   (progn
                     (set-frame-size nil 1100 750 t)
                     (setq web-test--source (web (getenv "WEB_TEST_URL")))
                     (run-at-time 0.2 0.2 #'web-test--step))
                 (error (web-test--finish nil (error-message-string err))))))
