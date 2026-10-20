(spec-library "org.starintel/star-face@1"
  (:version "1.0.0")

  (import "org.starintel/core@1"
    :version "1.0.0"
    :digest "sha256:3c1e7798577b50c3bda7498523134f1863697c7eb186064931285b301a9fb558"
    :path "vendor/starintel-core.star")

  (scalar face-id
    (:base string
     :pattern "^[a-f0-9]{64}$"))

  (enum match-state
    (candidate probable confirmed rejected unknown))

  (enum face-kind
    (probe gallery frame unknown))

  (enum search-by
    (embedding identity dataset))

  (enum search-status
    (ok empty rejected error))

  (document face-detection
    (:extends org.starintel/core@1/document
     :persistence persistent)
    (faceId face-id :required)
    (mediaRef string :required)
    (mediaKind face-kind :optional :default probe)
    (detector string :optional)
    (bbox (list integer) :optional)
    (detScore org.starintel/core@1/confidence-score :optional)
    (embedding (list decimal) :optional)
    (landmarks (list integer) :optional)
    (ageEstimate integer :optional)
    (genderEstimate string :optional)
    (personRef reference :optional)
    (identitySimilarity org.starintel/core@1/confidence-score :optional)
    (capturedAt org.starintel/core@1/unix-time :optional))

  (document face-match
    (:extends org.starintel/core@1/document
     :persistence persistent)
    (matchId org.starintel/core@1/document-id :required)
    (probeRef face-id :required)
    (galleryRef face-id :required)
    (similarity org.starintel/core@1/confidence-score :required)
    (matchState match-state :required)
    (threshold org.starintel/core@1/confidence-score :optional)
    (engine string :optional)
    (decidedAt org.starintel/core@1/unix-time :optional))

  (predicate face-identifies
    (:source face-detection :destination org.starintel/core@1/person))

  (predicate matched-against
    (:source face-detection :destination face-detection))

  (message face-result
    (:fields ((mediaRef string :required)
              (faces (list face-detection) :required)
              (engine string :optional)
              (capturedAt org.starintel/core@1/unix-time :optional))))

  (message ingest-result
    (:fields ((mediaRef string :required)
              (faceIds (list face-id) :required)
              (documentIds (list org.starintel/core@1/document-id) :required)
              (duplicates integer :required))))

  (message search-request
    (:fields ((queryId string :required)
              (searchBy search-by :required)
              (embedding (list decimal) :optional)
              (personRef reference :optional)
              (dataset string :optional)
              (minSimilarity org.starintel/core@1/confidence-score :optional)
              (limit integer :optional :default 25))))

  (message search-reply
    (:fields ((queryId string :required)
              (status search-status :required)
              (matches (list reference) :optional)
              (similarities (list decimal) :optional)
              (resultCount integer :optional)
              (error string :optional)))))
