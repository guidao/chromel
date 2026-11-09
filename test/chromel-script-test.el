;;; chromel-script-test.el --- Public script API tests -*- lexical-binding: t; -*-
(require 'ert)
(require 'chromel)

(defmacro chromel-script-test--with-page (&rest body)
  (declare (indent 0))
  `(let ((chromel--pages (make-hash-table))
         (chromel--script-requests (make-hash-table :test #'equal))
         (chromel--session-inhibit t)
         (chromel--tabs nil)
         calls)
     (cl-letf (((symbol-function 'chromel--native-command)
                (lambda (&rest args) (push args calls))))
       (with-temp-buffer
         (chromel-mode)
         (setq chromel--id 7)
         (puthash 7 (current-buffer) chromel--pages)
         (unwind-protect (progn ,@body)
           (chromel--script-abort-buffer (current-buffer))
           (sleep-for 0.01))))))

(defun chromel-script-test--reply (token result &optional failure undefined id)
  (chromel--handle-event
   (list :id (or id 7) :type "script"
         :value (chromel--json (list :token token :ok (if failure :false t)
                                    :result result :error (or failure "javascript")
                                    :undefined (if undefined t :false))))))

(ert-deftest chromel-script-concurrent-results-are-async-and-buffer-bound ()
  (chromel-script-test--with-page
    (let* ((target (current-buffer)) results
           (first (chromel-execute-script nil "1" (lambda (v) (push (list 'first v (current-buffer)) results))))
           (second (chromel-execute-script (buffer-name) "2" (lambda (v) (push (list 'second v (current-buffer)) results)))))
      (should-not (equal first second))
      (should (= (hash-table-count chromel--script-requests) 2))
      (chromel-script-test--reply second "2")
      (chromel-script-test--reply first "1")
      (should-not results)
      (with-temp-buffer (sleep-for 0.02))
      (should (equal (reverse results) (list (list 'second 2 target) (list 'first 1 target)))))))

(ert-deftest chromel-script-converts-results-and-keeps-private-eval-separate ()
  (chromel-script-test--with-page
    (setq chromel--eval-token "private")
    (dolist (entry '(("\"中文\"" nil "中文")
                     ("false" nil :false) ("null" nil :null) ("" t :undefined)
                     ("[1,2.5]" nil [1 2.5]) ("{\"name\":\"中文\"}" nil ((name . "中文")))))
      (let* (result (token (chromel-execute-script nil "ignored" (lambda (v) (setq result v)))))
        (chromel-script-test--reply token (nth 0 entry) nil (nth 1 entry))
        (sleep-for 0.01)
        (should (equal result (nth 2 entry)))))
    (should-not chromel--eval-reply)
    (should (equal chromel--eval-token "private"))))

(ert-deftest chromel-script-errors-are-delivered-once ()
  (chromel-script-test--with-page
    (dolist (kind '("javascript" "navigation"))
      (let* (failures
             (token (chromel-execute-script nil "throw 1" nil :on-error (lambda (e) (push e failures)))))
        (chromel-script-test--reply token "broken" kind)
        (chromel-script-test--reply token "42")
        (sleep-for 0.01)
        (should (= (length failures) 1))
        (should (eq (plist-get (car failures) :type) (intern kind)))
        (should-not (chromel-cancel-script token))))))

(ert-deftest chromel-script-timeout-and-cancel-discard-late-results ()
  (chromel-script-test--with-page
    (dolist (kind '(timeout cancelled))
      (let* (success failures
             (token (chromel-execute-script nil "1" (lambda (_) (setq success t))
                                            :on-error (lambda (e) (push e failures))
                                            :timeout 0.01)))
        (when (eq kind 'cancelled) (should (chromel-cancel-script token)))
        (sleep-for 0.03)
        (chromel-script-test--reply token "1")
        (sleep-for 0.01)
        (should-not success)
        (should (= (length failures) 1))
        (should (eq (plist-get (car failures) :type) kind))
        (should (member (list 7 "cancel-script" token) calls))
        (should-not (gethash token chromel--script-requests))))))

(ert-deftest chromel-script-kill-and-mode-change-cancel-requests ()
  (chromel-script-test--with-page
    (let (failure)
      (chromel-execute-script nil "1" nil :on-error (lambda (e) (setq failure e)))
      (fundamental-mode)
      (sleep-for 0.01)
      (should (eq (plist-get failure :type) 'closed))
      (should (= 0 (hash-table-count chromel--script-requests))))))

(ert-deftest chromel-script-closed-page-and-wrong-browser-replies ()
  (chromel-script-test--with-page
    (let* (failure result
           (token (chromel-execute-script nil "1" (lambda (v) (setq result v))
                                          :on-error (lambda (e) (setq failure e)))))
      (with-temp-buffer
        (puthash 8 (current-buffer) chromel--pages)
        (chromel-script-test--reply token "1" nil nil 8))
      (should (gethash token chromel--script-requests))
      (chromel--handle-event '(:id 7 :type "closed"))
      (sleep-for 0.01)
      (should-not result)
      (should (eq (plist-get failure :type) 'closed)))))

(ert-deftest chromel-script-transport-and-malformed-result-errors ()
  (chromel-script-test--with-page
    (let (failure)
      (cl-letf (((symbol-function 'chromel--native-command) (lambda (&rest _) (error "native failure"))))
        (chromel-execute-script nil "1" nil :on-error (lambda (e) (setq failure e))))
      (sleep-for 0.01)
      (should (eq (plist-get failure :type) 'transport))
      (should (= 0 (hash-table-count chromel--script-requests)))
      (setq failure nil)
      (let ((token (chromel-execute-script nil "1" nil :on-error (lambda (e) (setq failure e)))))
        (chromel-script-test--reply token "not JSON")
        (sleep-for 0.01)
        (should (eq (plist-get failure :type) 'result))))))

(ert-deftest chromel-script-validates-before-sending ()
  (chromel-script-test--with-page
    (dolist (args '((nil 42) (nil "1" 42) (nil "1" nil :on-error 42)
                    (nil "1" nil :timeout 0) (nil "1" nil :timeout -1)
                    (nil "1" nil :timeout 1.0e+INF) (nil "1" nil :timeout 0.0e+NaN)
                    ("missing-page" "1")))
      (should-error (apply #'chromel-execute-script args)))
    (should-not calls)
    (should (= 0 (hash-table-count chromel--script-requests)))))

(ert-deftest chromel-script-callback-errors-do-not-stop-other-callbacks ()
  (chromel-script-test--with-page
    (let* (result
           (first (chromel-execute-script nil "1" (lambda (_) (error "user callback failed"))))
           (second (chromel-execute-script nil "2" (lambda (v) (setq result v)))))
      (chromel-script-test--reply first "1")
      (chromel-script-test--reply second "2")
      (sleep-for 0.02)
      (should (= result 2))
      (should (= 0 (hash-table-count chromel--script-requests))))))
