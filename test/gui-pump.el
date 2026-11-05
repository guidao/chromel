;;; gui-pump.el --- Guard against CEF reentering the host's NSApp.run -*- lexical-binding: t; -*-
(require 'chromel)
(when-let* ((module (getenv "CHROMEL_TEST_NATIVE_MODULE")))
  (setq chromel-native-module module))
(setq chromel-data-directory (file-name-as-directory (getenv "CHROMEL_TEST_PROFILE")))
(defvar chromel-test--calls 0)
(defvar chromel-test--runs 0)
(defvar chromel-test--source nil)
(defvar chromel-test--busy nil)
(defvar chromel-test--phase 'loading)
(defvar chromel-test--cycles 0)
(defvar chromel-test--deadline (+ (float-time) 45))
(defun chromel-test--pump (function &rest args)
  (cl-incf chromel-test--calls)
  (chromel-test-pump-probe t)
  (unwind-protect (apply function args)
    (setq chromel-test--runs (chromel-test-pump-probe nil))))
(defun chromel-test--finish (ok text)
  (with-temp-file (getenv "CHROMEL_TEST_RESULT") (insert (if ok "PASS: " "FAIL: ") text "\n"))
  (kill-emacs (if ok 0 1)))
(defun chromel-test--step ()
  (unless chromel-test--busy
    (let ((chromel-test--busy t))
      (with-current-buffer (window-buffer (selected-window))
        (condition-case err
            (progn
              (when (> (float-time) chromel-test--deadline) (error "Pump stress timed out"))
              (unless (or (getenv "CHROMEL_TEST_EXPECT_REENTRY") (= chromel-test--runs 0))
                (error "CEF reentered NSApp.run %d times in %d pump calls" chromel-test--runs chromel-test--calls))
              (pcase chromel-test--phase
                ('loading
                 (when (equal (buffer-local-value 'chromel--title chromel-test--source)
                              (getenv "CHROMEL_TEST_EXPECT_TITLE"))
                   (if (getenv "CHROMEL_TEST_EXPECT_REENTRY")
                       (progn
                         (unless (> chromel-test--runs 0) (error "Old module did not reproduce NSApp.run reentry"))
                         (chromel-test--finish t (format "Old module reproduces NSApp.run reentry: %d / %d pump calls" chromel-test--runs chromel-test--calls)))
                     (switch-to-buffer chromel-test--source)
                     (delete-other-windows)
                     (chromel--sync)
                     (chromel--command "unfocus")
                     ;; Keep compositor and renderer tasks active during churn.
                     (chromel--eval "JSON.stringify(((()=>{let c=document.createElement('canvas');c.width=400;c.height=100;document.body.prepend(c);let x=c.getContext('2d');function draw(t){x.fillStyle='hsl('+t%360+',60%,50%)';x.fillRect(0,0,400,100);requestAnimationFrame(draw)}requestAnimationFrame(draw);return true})()))")
                     (setq chromel-test--phase 'churn))))
                ('churn
                 (if (>= chromel-test--cycles 60)
                     (progn
                       (dolist (buffer (chromel--buffers)) (kill-buffer buffer))
                       (setq chromel-test--phase 'closing))
                   ;; Exercise visible/hidden lifecycle, focus, and queued work.
                   (pcase (mod chromel-test--cycles 3)
                     (0 (chromel (getenv "CHROMEL_TEST_URL") t))
                     (1 (chromel-next-tab)
                        (chromel-scroll-down)
                        (chromel--eval "JSON.stringify(document.readyState)"))
                     (2 (unless (eq (current-buffer) chromel-test--source) (chromel-close-tab))
                        (chromel--select-buffer chromel-test--source)))
                   (cl-incf chromel-test--cycles)))
                ('closing
                 (when (string-match-p "Browsers including DevTools: 0" (chromel--native-info))
                   (unless (> chromel-test--calls 100) (error "Insufficient pump coverage"))
                   (chromel-test--finish t (format "External pump: %d calls, %d NSApp.run reentries, %d lifecycle steps, all browsers closed"
                                              chromel-test--calls chromel-test--runs chromel-test--cycles))))))
          (error (chromel-test--finish nil (format "%s (phase %s)" (error-message-string err) chromel-test--phase))))))))
(run-at-time 1 nil
             (lambda ()
               (condition-case err
                   (progn
                     (setq chromel-test--source (chromel (getenv "CHROMEL_TEST_URL")))
                     (module-load (expand-file-name "build/chromel-pump-probe.dylib" chromel--directory))
                     (advice-add 'chromel--native-pump :around #'chromel-test--pump)
                     (run-at-time 0.2 0.2 #'chromel-test--step))
                 (error (chromel-test--finish nil (error-message-string err))))))
