(defpackage :star-face/t
  (:use :cl :fiveam)
  (:import-from :starlangruntime
                #:make-deterministic-dispatcher
                #:register-dispatch-actor
                #:submit-dispatch-envelope
                #:run-dispatcher
                #:run-dispatcher-next
                #:redeliver-command
                #:drain-dispatcher-emitted)
  (:export #:run-all))

(in-package :star-face/t)

(def-suite* star-face-suite)

(defvar *repo-root*
  (let ((dir (uiop:getenv "STAR_FACE_ROOT")))
    (if (and dir (plusp (length dir)) (uiop:directory-exists-p dir))
        (uiop:truenamize (pathname (concatenate 'string (string-right-trim "/" dir) "/")))
        *default-pathname-defaults*)))

(defvar *fixed-clock* "2026-09-24T00:00:00Z")

(defun repo-file (relative)
  (merge-pathnames relative *repo-root*))

(defun portable-manifest ()
  "Build the runtime portable manifest from the real compiled library and
actor units, merging every library in the locked graph."
  (let* ((graph (star-lang.loader:load-star-file
                 (repo-file "spec/star-face.star")
                 :cache-directory (repo-file ".cache/specs/")))
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

(defun sample-payload (&key clock person)
  "Wire payload (alist) for one InsightFace-style result with one face."
  (let ((face
          (append
           (list (cons "id" (star-face::sha256-hex "stable-face-material"))
                 (cons "faceId" (star-face::sha256-hex "stable-face-material"))
                 (cons "dataset" "star-face")
                 (cons "dtype" "observation")
                 (cons "schemaVersion" "0.9.0")
                 (cons "mediaRef" "/probes/t1.jpg")
                 (cons "bbox" '(10 20 110 120))
                 (cons "detScore" "0.9500")
                 (cons "embedding" '("0.100000" "0.200000" "0.300000")))
           (when person
             (list (cons "personRef" (list (cons "schema" "starintel/person")
                                           (cons "id" "person-alice")))
                   (cons "identitySimilarity" "0.9300"))))))
    (list (cons "mediaRef" "/probes/t1.jpg")
          (cons "faces" (list face))
          (cons "engine" "insightface")
          (cons "capturedAt" 1782000000))))

(defun make-command (message-type actor payload &key (message-id "cmd-1") (key "idem-1"))
  (staractorprotocol:make-command-envelope
   :message-id message-id
   :message-type message-type
   :actor actor
   :sender "test-suite"
   :idempotency-key key
   :payload payload))

(defun reply-envelopes (dispatcher)
  (loop for envelope in (drain-dispatcher-emitted dispatcher)
        when (eq (getf envelope :kind) :reply)
          collect envelope))

(defvar *temp-counter* 0)

(defun temp-storage (name)
  (let ((root
          (uiop:merge-pathnames*
           (make-pathname
            :directory
            `(:relative
              ,(format nil "star-face-tests-~D" (sb-unix:unix-getpid))
              ,(format nil "~A-~D-~D" name (get-universal-time) (incf *temp-counter*))))
           (or (uiop:temporary-directory) #p"/tmp/"))))
    (ensure-directories-exist root)
    root))

(test insightface-json-parses-to-wire-payload
  (let* ((json "[{\"bbox\":[1.0,2.0,3.0,4.0],\"kps\":[[1.0,1.0],[2.0,2.0]],\"det_score\":0.87,\"embedding\":[0.5,0.5,0.5],\"age\":33,\"gender\":1}]")
         (payload (star-face:insightface->payload json "/x.jpg" :engine "insightface")))
    (is (string= (cdr (assoc "mediaRef" payload :test #'string=)) "/x.jpg"))
    (let ((face (first (cdr (assoc "faces" payload :test #'string=)))))
      (is (string= (cdr (assoc "detScore" face :test #'string=)) "0.8700"))
      (is (equal (cdr (assoc "bbox" face :test #'string=)) '(1 2 3 4)))
      (is (equal (cdr (assoc "landmarks" face :test #'string=)) '(1 1 2 2)))
      (is (= (cdr (assoc "ageEstimate" face :test #'string=)) 33))
      (is (string= (cdr (assoc "genderEstimate" face :test #'string=)) "male"))
      (is (every #'stringp (cdr (assoc "embedding" face :test #'string=)))))))

(test face-id-is-stable
  (let* ((faces (star-face:parse-insightface-json
                 "[{\"bbox\":[1,2,3,4],\"det_score\":0.9,\"embedding\":[1.0,2.0]}]" "/a.jpg"))
         (face (first faces)))
    (is (string= (star-face:face-id face) (star-face:face-id face)))
    (is (= 64 (length (star-face:face-id face))))))

(test derive-documents-are-deterministic
  (let ((docs (star-face:derive-documents (sample-payload) :clock *fixed-clock*)))
    (is (= 2 (length docs)))
    (labels ((serialized (documents)
               (with-output-to-string (out)
                 (dolist (d documents) (star-face::write-json d out) (terpri out)))))
      (is (string= (serialized docs)
                   (serialized (star-face:derive-documents
                                (sample-payload) :clock *fixed-clock*)))))
    (let ((observation (find "observation" docs
                             :key (lambda (doc) (cdr (assoc "dtype" doc :test #'string=)))
                             :test #'string=)))
      (is (string= (cdr (assoc "schema_version" observation :test #'string=)) "0.9.0"))
      (is (string= (cdr (assoc "dataset" observation :test #'string=)) "star-face"))
      (is (string= (cdr (assoc "observed_property"
                               (cdr (assoc "data" observation :test #'string=))
                               :test #'string=))
                   "face")))))

(test derive-documents-with-identity-yields-person-and-relation
  (let ((docs (star-face:derive-documents (sample-payload :person t) :clock *fixed-clock*)))
    (is (= 4 (length docs)))
    (is (find "person" docs :key (lambda (doc) (cdr (assoc "dtype" doc :test #'string=)))
              :test #'string=))
    (let ((relation (find "relation" docs
                          :key (lambda (doc) (cdr (assoc "dtype" doc :test #'string=)))
                          :test #'string=)))
      (is (string= (cdr (assoc "predicate" (cdr (assoc "data" relation :test #'string=))
                                    :test #'string=))
                   "face-identifies")))))

(test storage-append-is-idempotent
  (let* ((root (temp-storage "star-face-idempotent"))
         (docs (star-face:derive-documents (sample-payload) :clock *fixed-clock*)))
    (let ((star-face::*storage-root* root))
      (is (eq :appended (star-face:append-document (first docs))))
      (is (eq :duplicate (star-face:append-document (first docs))))
      (let ((reloaded (star-face:load-document
                       (cdr (assoc "dtype" (first docs) :test #'string=))
                       (cdr (assoc "_id" (first docs) :test #'string=)))))
        (is (string= (cdr (assoc "_id" reloaded :test #'string=))
                     (cdr (assoc "_id" (first docs) :test #'string=))))))))

(defun run-dispatch-with-handlers (manifest commands)
  (let ((dispatcher (make-deterministic-dispatcher manifest)))
    (starlangruntime:register-dispatch-actor
     dispatcher "face-ingest" #'star-face:face-ingest-handler)
    (starlangruntime:register-dispatch-actor
     dispatcher "face-search" #'star-face:face-search-handler)
    (dolist (command commands)
      (submit-dispatch-envelope dispatcher command))
    (let ((statuses (run-dispatcher dispatcher)))
      (values dispatcher statuses))))

(test ingest-handler-roundtrip-through-real-dispatcher
  (let* ((manifest (portable-manifest))
         (root (temp-storage "star-face-ingest"))
         (star-face::*storage-root* root)
         (star-face::*clock-function* (lambda () *fixed-clock*)))
    (multiple-value-bind (dispatcher statuses)
        (run-dispatch-with-handlers
         manifest
         (list (make-command star-face:+msg-face-result+ "face-ingest"
                             (sample-payload))))
      (is (equal '(:completed) statuses))
      (let ((replies (reply-envelopes dispatcher)))
        (is (= 1 (length replies)))
        (let ((payload (getf (first replies) :payload)))
          (is (= 0 (cdr (assoc "duplicates" payload :test #'string=))))
          (is (= 1 (length (cdr (assoc "faceIds" payload :test #'string=)))))))
      (let ((observations (star-face:scan-dtype "observation"))
            (media (star-face:scan-dtype "media")))
        (is (= 1 (length observations)))
        (is (= 1 (length media)))))))

(test duplicate-redelivery-replays-without-new-documents
  (let* ((manifest (portable-manifest))
         (root (temp-storage "star-face-redelivery"))
         (star-face::*storage-root* root)
         (star-face::*clock-function* (lambda () *fixed-clock*))
         (dispatcher (make-deterministic-dispatcher manifest)))
    (starlangruntime:register-dispatch-actor
     dispatcher "face-ingest" #'star-face:face-ingest-handler)
    (starlangruntime:register-dispatch-actor
     dispatcher "face-search" #'star-face:face-search-handler)
    (let ((command (make-command star-face:+msg-face-result+ "face-ingest"
                                 (sample-payload))))
      (submit-dispatch-envelope dispatcher command)
      (is (equal '(:completed) (run-dispatcher dispatcher)))
      (drain-dispatcher-emitted dispatcher)
      (let ((redelivery (starlangruntime:redeliver-command
                         dispatcher command :message-id "cmd-redelivery")))
        (submit-dispatch-envelope dispatcher redelivery)
        (is (eq :duplicate (run-dispatcher-next dispatcher)))
        (is (= 1 (length (star-face:scan-dtype "observation"))))))))

(test search-by-identity-finds-ingested-face
  (let* ((manifest (portable-manifest))
         (root (temp-storage "star-face-search-identity"))
         (star-face::*storage-root* root)
         (star-face::*clock-function* (lambda () *fixed-clock*)))
    (multiple-value-bind (dispatcher statuses)
        (run-dispatch-with-handlers
         manifest
         (list (make-command star-face:+msg-face-result+ "face-ingest"
                             (sample-payload :person t))
               (make-command star-face:+msg-search-request+ "face-search"
                             (list (cons "queryId" "q1")
                                   (cons "searchBy" "identity")
                                   (cons "personRef" (list (cons "schema" "starintel/person")
                                                           (cons "id" "person-alice"))))
                             :message-id "cmd-2" :key "idem-2")))
      (is (equal '(:completed :completed) statuses))
      (let ((search-reply (find star-face:+msg-search-reply+
                                (reply-envelopes dispatcher)
                                :key (lambda (e) (getf e :message-type))
                                :test #'string=)))
        (is (string= (getf search-reply :message-type)
                     star-face:+msg-search-reply+))
        (let ((payload (getf search-reply :payload)))
          (is (string= (cdr (assoc "status" payload :test #'string=)) "ok"))
          (is (= 1 (cdr (assoc "resultCount" payload :test #'string=)))))))))

(test search-by-embedding-ranks-matching-face-first
  (let* ((manifest (portable-manifest))
         (root (temp-storage "star-face-search-embedding"))
         (star-face::*storage-root* root)
         (star-face::*clock-function* (lambda () *fixed-clock*)))
    (multiple-value-bind (dispatcher statuses)
        (run-dispatch-with-handlers
         manifest
         (list (make-command star-face:+msg-face-result+ "face-ingest"
                             (sample-payload))
               (make-command star-face:+msg-search-request+ "face-search"
                             (list (cons "queryId" "q2")
                                   (cons "searchBy" "embedding")
                                   (cons "embedding" '("0.100000" "0.200000" "0.300000"))
                                   (cons "minSimilarity" "0.9000"))
                             :message-id "cmd-3" :key "idem-3")))
      (is (equal '(:completed :completed) statuses))
      (let* ((reply (find star-face:+msg-search-reply+
                          (reply-envelopes dispatcher)
                          :key (lambda (e) (getf e :message-type))
                          :test #'string=))
             (payload (getf reply :payload)))
        (is (string= (cdr (assoc "status" payload :test #'string=)) "ok"))
        (is (= 1 (cdr (assoc "resultCount" payload :test #'string=))))))))

(test empty-search-replies-explicitly
  (let* ((manifest (portable-manifest))
         (root (temp-storage "star-face-search-empty"))
         (star-face::*storage-root* root)
         (star-face::*clock-function* (lambda () *fixed-clock*)))
    (multiple-value-bind (dispatcher statuses)
        (run-dispatch-with-handlers
         manifest
         (list (make-command star-face:+msg-search-request+ "face-search"
                             (list (cons "queryId" "q3")
                                   (cons "searchBy" "identity")
                                   (cons "personRef" (list (cons "schema" "starintel/person")
                                                           (cons "id" "nobody"))))
                             :message-id "cmd-4" :key "idem-4")))
      (is (equal '(:completed) statuses))
      (let ((payload (getf (first (reply-envelopes dispatcher)) :payload)))
        (is (string= (cdr (assoc "status" payload :test #'string=)) "empty"))
        (is (= 0 (cdr (assoc "resultCount" payload :test #'string=))))))))

(test ingest-handler-rejects-missing-media-ref
  (let ((result (star-face:face-ingest-handler nil
                                               (list :payload
                                                     (list (cons "faces" nil))))))
    (is (eq :fail (getf result :outcome)))
    (is (string= (getf result :code) "star.face/malformed-result"))))

(defun run-all ()
  (let ((results (run 'star-face-suite)))
    (values (results-status results) results)))
