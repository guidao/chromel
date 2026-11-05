;;; gui-smoke.el --- Run in an isolated GUI Emacs -*- lexical-binding: t; -*-
(require 'chromel)
(setq chromel-data-directory (file-name-as-directory (getenv "CHROMEL_TEST_PROFILE")))
(defvar chromel-test--buffer nil)
(defvar chromel-test--original-frame nil)
(defvar chromel-test--second-frame nil)
(defvar chromel-test--deadline (+ (float-time) 35))
(defvar chromel-test--phase 'loading)

(defun chromel-test--finish (success description)
  (with-temp-file (getenv "CHROMEL_TEST_RESULT")
    (insert (if success "PASS: " "FAIL: ") description "\n"))
  (kill-emacs (if success 0 1)))

(defun chromel-test--assert (value message)
  (unless value (error "%s" message)))

(defun chromel-test--step ()
  (condition-case err
      (progn
        (when (> (float-time) chromel-test--deadline)
          (error "Timed out in phase %s" chromel-test--phase))
        (pcase chromel-test--phase
          ('loading
           (when (with-current-buffer chromel-test--buffer
                   (equal chromel--title (getenv "CHROMEL_TEST_EXPECT_TITLE")))
             (chromel-test--assert chromel--timer "CEF pump stopped")
             (chromel-test--assert (eq (window-buffer (selected-window)) chromel-test--buffer)
                               "Opening a page did not select its Emacs window")
             (chromel-test--assert
              (eq t (plist-get
                     (json-parse-string
                      (chromel--native-inspect (buffer-local-value 'chromel--id chromel-test--buffer))
                      :object-type 'plist)
                     :focused))
              "New page did not receive keyboard focus automatically")
             (delete-other-windows)
             (switch-to-buffer (get-buffer-create "*Chromel smoke sibling*"))
             (let ((right (split-window-right)))
               (set-window-buffer right chromel-test--buffer)
               (select-window right))
             (chromel--sync)
             (chromel-test--assert (eq chromel--window (selected-window)) "Wrong split selected")
             (let* ((actual (json-parse-string (chromel--native-inspect chromel--id) :object-type 'plist))
                    (edges (window-inside-pixel-edges)))
               (chromel-test--assert (and (= (plist-get actual :x) (nth 0 edges))
                                      (= (plist-get actual :y) (nth 1 edges))
                                      (= (plist-get actual :width) (- (nth 2 edges) (nth 0 edges)))
                                      (= (plist-get actual :height) (- (nth 3 edges) (nth 1 edges))))
                                 "Native Cocoa geometry disagrees with Emacs split"))
             (chromel-focus)
             (chromel--release-focus)
             (chromel-test--assert
              (eq :false (plist-get (json-parse-string (chromel--native-inspect chromel--id)
                                                     :object-type 'plist) :focused))
              "Focus did not return to Emacs")
             (setq chromel-test--second-frame (make-frame '((name . "Chromel smoke second"))))
             (select-frame-set-input-focus chromel-test--second-frame)
             (switch-to-buffer chromel-test--buffer)
             (chromel--sync)
             (setq chromel-test--phase 'reparented)))
          ('reparented
           (chromel-test--assert (eq (window-frame chromel--window) chromel-test--second-frame)
                             "View did not follow its buffer to the second frame")
           (delete-frame chromel-test--second-frame)
           (select-frame-set-input-focus chromel-test--original-frame)
           (switch-to-buffer chromel-test--buffer)
           (chromel--sync)
           (kill-buffer chromel-test--buffer)
           (setq chromel-test--phase 'closing))
          ('closing
           (when (string-match-p "Browsers including DevTools: 0" (chromel--native-info))
             (chromel-test--assert (frame-live-p chromel-test--original-frame) "Host frame was closed")
             (chromel-test--finish t "GUI Emacs renderer, native geometry, focus API, two frames, close")))))
    (error (chromel-test--finish nil (error-message-string err)))))

(run-at-time
 1 nil
 (lambda ()
   (condition-case err
       (progn
         (setq chromel-test--original-frame (selected-frame))
         (setq chromel-test--buffer
               (chromel (getenv "CHROMEL_TEST_URL")))
         (run-at-time 0.2 0.2 #'chromel-test--step))
     (error (chromel-test--finish nil (error-message-string err))))))
