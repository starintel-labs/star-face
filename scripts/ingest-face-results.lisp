;;;; Ingest engine face-results into the star-face domain.
;;;; Usage: sbcl --script scripts/ingest-face-results.lisp RESULTS.jsonl
;;;; Reads the engine envelope JSONL and dispatches one face-result message
;;;; per line through the deterministic dispatcher into db/<dtype>/.

(require :asdf)

(defparameter *star-lang-src*
  (or (uiop:getenv "STAR_LANG_SRC")
      (error "STAR_LANG_SRC must point at the star-lang source tree.")))

(unless (find-package "STAR-LANG.API")
  (load (merge-pathnames "prototype/star-lang-api.lisp"
                         (pathname (concatenate 'string *star-lang-src* "/")))))

(asdf:initialize-source-registry)
(asdf:load-system :star-face)
(asdf:load-system :starlang-compiler)

(defparameter *repo-root*
  (concatenate 'string
               (string-right-trim "/"
                                  (or (uiop:getenv "STAR_FACE_ROOT")
                                      (error "STAR_FACE_ROOT must point at the star-face repository.")))
               "/"))

(defun repo-file (relative)
  (merge-pathnames relative *repo-root*))

(defun spec-cache-directory ()
  (or (uiop:getenv "STAR_FACE_CACHE_SPECS")
      (repo-file ".cache/specs/")))

(defun portable-manifest ()
  (let* ((graph (star-lang.loader:load-star-file
                 (repo-file "spec/star-face.star")
                 :cache-directory (spec-cache-directory)))
         (core-library
           (loop for node in (star-lang.loader:loaded-graph-libraries graph)
                 when (string= (star-lang.loader:library-node-name node)
                               "org.starintel/core@1")
                   return (star-lang.loader:library-node-compiled node)))
         (actors
           (list (starlangcompiler:compile-actor-file
                  (repo-file "actors/face-ingest.star"))
                 (starlangcompiler:compile-actor-file
                  (repo-file "actors/face-search.star"))))
         (root-library
          (star-lang.loader:library-node-compiled
           (star-lang.loader:loaded-graph-root graph)))
         (core-types
           (getf (starlangcompiler:emit-portable-manifest core-library '())
                 :types)))
    (let ((manifest (starlangcompiler:emit-portable-manifest root-library actors)))
      (setf (getf manifest :types)
            (append (getf manifest :types) core-types))
      manifest)))

(defun wire-value (payload key)
  (cdr (assoc key payload :test #'string=)))

(defun ingest-line (dispatcher line index)
  (let* ((envelope (yason:parse line))
         (media-ref (gethash "mediaRef" envelope))
         (engine (gethash "engine" envelope))
         (faces (gethash "faces" envelope)))
    (cond
      ((not (and media-ref (listp faces)))
       (format *error-output* "line ~D: expected mediaRef and faces array; skipped~%" index))
      ((null faces)
       (format *error-output* "~A: no faces; skipped~%" media-ref))
      (t
       (let* ((faces-text
                (with-output-to-string (out)
                  (yason:encode faces out)))
              (payload (star-face:insightface->payload faces-text media-ref
                                                       :engine engine))
              (command
                (staractorprotocol:make-command-envelope
                 :message-id (format nil "ingest-~D" index)
                 :message-type star-face:+msg-face-result+
                 :actor "face-ingest"
                 :sender "face-engine"
                 :idempotency-key
                 (star-face::sha256-hex (format nil "engine|~A" media-ref))
                 :payload payload)))
         (starlangruntime:submit-dispatch-envelope dispatcher command))))))

(defun main ()
  (when (or (null (second sb-ext:*posix-argv*))
            (not (uiop:file-exists-p (second sb-ext:*posix-argv*))))
    (format *error-output* "usage: ingest-face-results.lisp RESULTS.jsonl~%")
    (uiop:quit 2))
  (when (uiop:getenv "STAR_FACE_DB")
    (setf star-face:*storage-root*
          (pathname (concatenate 'string (string-right-trim "/" (uiop:getenv "STAR_FACE_DB")) "/"))))
  ;; A pinned clock makes derived documents byte-identical across redelivery
  ;; and process restarts, enabling durable storage-level dedupe.
  (let ((clock (uiop:getenv "STAR_FACE_CLOCK")))
    (when clock
      (setf star-face:*clock-function* (lambda () clock))))
  (let ((dispatcher (starlangruntime:make-deterministic-dispatcher
                     (portable-manifest))))
    (starlangruntime:register-dispatch-actor
     dispatcher "face-ingest" #'star-face:face-ingest-handler)
    (starlangruntime:register-dispatch-actor
     dispatcher "face-search" #'star-face:face-search-handler)
    (with-open-file (stream (second sb-ext:*posix-argv*))
      (loop for line = (read-line stream nil nil)
            for index from 1
            while line
            when (plusp (length (string-trim " " line)))
              do (ingest-line dispatcher line index)))
    (let ((statuses (starlangruntime:run-dispatcher dispatcher)))
      (format t "~&ingest statuses: ~A~%" statuses)
      (let ((replies
              (loop for envelope in (starlangruntime:drain-dispatcher-emitted dispatcher)
                    when (eq (getf envelope :kind) :reply)
                      collect (getf envelope :payload))))
        (let ((faces 0) (documents 0) (duplicates 0))
          (dolist (reply replies)
            (let ((count (length (wire-value reply "faceIds"))))
              (incf faces count)
              (format t "~&~A faces:~D documents:~D duplicates:~D~%"
                      (wire-value reply "mediaRef")
                      count
                      (length (wire-value reply "documentIds"))
                      (wire-value reply "duplicates")))
            (incf documents (length (wire-value reply "documentIds")))
            (incf duplicates (wire-value reply "duplicates")))
          (format t "~&total replies:~D faces:~D documents:~D duplicates:~D~%"
                  (length replies) faces documents duplicates))
        (uiop:quit 0)))))

(main)
