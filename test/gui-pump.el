;;; gui-pump.el --- Guard against CEF reentering the host's NSApp.run -*- lexical-binding: t; -*-
(require 'web)
(when-let* ((module (getenv "WEB_TEST_NATIVE_MODULE")))
  (setq web-native-module module))
(setq web-data-directory (file-name-as-directory (getenv "WEB_TEST_PROFILE")))
(defvar web-test--calls 0)
(defvar web-test--runs 0)
(defvar web-test--source nil)
(defvar web-test--busy nil)
(defvar web-test--phase 'loading)
(defvar web-test--cycles 0)
(defvar web-test--deadline (+ (float-time) 45))
(defun web-test--pump (function &rest args)
  (cl-incf web-test--calls)
  (web-test-pump-probe t)
  (unwind-protect (apply function args)
    (setq web-test--runs (web-test-pump-probe nil))))
(defun web-test--finish (ok text)
  (with-temp-file (getenv "WEB_TEST_RESULT") (insert (if ok "PASS: " "FAIL: ") text "\n"))
  (kill-emacs (if ok 0 1)))
(defun web-test--step ()
  (unless web-test--busy
    (let ((web-test--busy t))
      (with-current-buffer (window-buffer (selected-window))
        (condition-case err
            (progn
              (when (> (float-time) web-test--deadline) (error "Pump stress timed out"))
              (unless (or (getenv "WEB_TEST_EXPECT_REENTRY") (= web-test--runs 0))
                (error "CEF reentered NSApp.run %d times in %d pump calls" web-test--runs web-test--calls))
              (pcase web-test--phase
                ('loading
                 (when (equal (buffer-local-value 'web--title web-test--source)
                              (getenv "WEB_TEST_EXPECT_TITLE"))
                   (if (getenv "WEB_TEST_EXPECT_REENTRY")
                       (progn
                         (unless (> web-test--runs 0) (error "Old module did not reproduce NSApp.run reentry"))
                         (web-test--finish t (format "Old module reproduces NSApp.run reentry: %d / %d pump calls" web-test--runs web-test--calls)))
                     (switch-to-buffer web-test--source)
                     (delete-other-windows)
                     (web--sync)
                     (web--command "unfocus")
                     ;; Keep compositor and renderer tasks active during churn.
                     (web--eval "JSON.stringify(((()=>{let c=document.createElement('canvas');c.width=400;c.height=100;document.body.prepend(c);let x=c.getContext('2d');function draw(t){x.fillStyle='hsl('+t%360+',60%,50%)';x.fillRect(0,0,400,100);requestAnimationFrame(draw)}requestAnimationFrame(draw);return true})()))")
                     (setq web-test--phase 'churn))))
                ('churn
                 (if (>= web-test--cycles 60)
                     (progn
                       (dolist (buffer (web--buffers)) (kill-buffer buffer))
                       (setq web-test--phase 'closing))
                   ;; Exercise visible/hidden lifecycle, focus, and queued work.
                   (pcase (mod web-test--cycles 3)
                     (0 (web (getenv "WEB_TEST_URL") t))
                     (1 (web-next-tab)
                        (web-scroll-down)
                        (web--eval "JSON.stringify(document.readyState)"))
                     (2 (unless (eq (current-buffer) web-test--source) (web-close-tab))
                        (web--select-buffer web-test--source)))
                   (cl-incf web-test--cycles)))
                ('closing
                 (when (string-match-p "Browsers including DevTools: 0" (web--native-info))
                   (unless (> web-test--calls 100) (error "Insufficient pump coverage"))
                   (web-test--finish t (format "External pump: %d calls, %d NSApp.run reentries, %d lifecycle steps, all browsers closed"
                                              web-test--calls web-test--runs web-test--cycles))))))
          (error (web-test--finish nil (format "%s (phase %s)" (error-message-string err) web-test--phase))))))))
(run-at-time 1 nil
             (lambda ()
               (condition-case err
                   (progn
                     (setq web-test--source (web (getenv "WEB_TEST_URL")))
                     (module-load (expand-file-name "build/web-pump-probe.dylib" web--directory))
                     (advice-add 'web--native-pump :around #'web-test--pump)
                     (run-at-time 0.2 0.2 #'web-test--step))
                 (error (web-test--finish nil (error-message-string err))))))
