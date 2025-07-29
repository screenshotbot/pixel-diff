;;;; Copyright 2018-Present Modern Interpreters Inc.
;;;;
;;;; This Source Code Form is subject to the terms of the Mozilla Public
;;;; License, v. 2.0. If a copy of the MPL was not distributed with this
;;;; file, You can obtain one at https://mozilla.org/MPL/2.0/.

(defpackage :deliver-utils/common
  (:use #:cl)
  (:export
   #:deliver-common
   #:guess-root))
(in-package :deliver-utils/common)

(defvar *kernel-restart-fn* nil)

(defun prepare-image-on-restart ()
  (uiop:setup-command-line-arguments)
  (setf sys:*line-arguments-list*
        (funcall
         (cond
           (*kernel-restart-fn*
            #'identity)
           (t
            ;; the first argument is the lisp script to load
            #'cdr))
         (uiop:raw-command-line-arguments)))
  (uiop:setup-command-line-arguments))

(defun fake-compile-file-pathname (input &key output-file)
  (or
   output-file
   (make-pathname :type "64ufasl"
                  :defaults input)))

(defun fake-compile-file (&rest args)
  (error "Compile-file unavailable: ~S" args))

(defun prepare-non-local-image-on-restart ()
  (setf (fdefinition 'cl:compile-file) #'fake-compile-file)
  (setf (fdefinition 'cl:compile-file-pathname)  #'fake-compile-file-pathname))


(defun kernel-init ()
  (log4cl::init-hook)
  (prepare-image-on-restart)
  (cond
    (*kernel-restart-fn*
     (funcall *kernel-restart-fn*))
    (t
     (load (car (uiop:raw-command-line-arguments))))))

(defun kernel-init-for-non-local (&rest args)
  (prepare-non-local-image-on-restart)
  (apply #'kernel-init args))

(defun kernel-init-for-local (&rest args)
  (apply #'kernel-init args)
  (uiop:quit 0))

(defun guess-root ()
  (let ((binary (path:catfile
                 (uiop:getcwd)
                 (car sys:*line-arguments-list*))))
    (labels ((guess (dir)
               (log:debug "Looking at: ~a" dir)
               (let ((parent (fad:pathname-parent-directory dir)))
                 (cond
                   ((equal parent dir)
                    (error "Could not find source root directory"))
                   ((path:-e (path:catfile dir "scripts/asdf.lisp"))
                    dir)
                   (t
                    (guess parent))))))
      (guess (fad:pathname-directory-pathname binary)))))


(defun deliver-common (output &rest args &key restart-fn
                                           (prepare-asdf t)
                                           (keep-modules t)
                                           (deliver-level 0)
                                           (require-modules t)
                       &allow-other-keys)
  ;; These systems are stubborn to reload They used to be a dependency
  ;; to #:deliver-utils system, but that caused its own issues during
  ;; test runs with recursive stacks.
  (ql:quickload :lisp-namespace)
  (ql:quickload :trivia)

  (ensure-directories-exist output)
  (log4cl::save-hook)
  (unless require-modules
    (require "remote-debugger-client")
    (require "remote-debugger-full")
    (require "profile"))

  (asdf:register-immutable-system :documentation-utils)

  (uiop:setup-command-line-arguments)
  (setf *kernel-restart-fn* restart-fn)

  (when prepare-asdf
    (uiop:call-function "cl-user::unprepare-asdf"
                        #'guess-root))
  (cond
    ((member "-local" (uiop:raw-command-line-arguments)
             :test #'string-equal)
     (setf output
           (make-pathname
            :name (format nil "~a-local" (pathname-name output))
            :defaults (pathname output)))
     (hcl:save-image output
                     :restart-function (lambda ()
                                         (kernel-init-for-local))
                     :multiprocessing t
                     :console t
                     :environment nil))
    (t
     (let* ((output (path:catfile (uiop:getcwd) output)))
       (delete-file output)
       (apply #'lw:deliver
              (lambda ()
                (kernel-init-for-non-local))
              output deliver-level
              :keep-modules keep-modules
              :packages-to-keep-symbol-names :all
              :keep-symbols `(system:pipe-exit-status)
              :keep-debug-mode t
              :keep-pretty-printer t
              :multiprocessing t
              (alexandria:remove-from-plist args :restart-fn :deliver-level
                                                 :prepare-asdf
                                                             :require-modules)))))
  (uiop:quit 0))
