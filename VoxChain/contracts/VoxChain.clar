;; VoxChain - Decentralized Governance Platform
;; Empowering voices through blockchain transparency

;; System Constants
(define-constant voxchain-admin tx-sender)
(define-constant error-unauthorized-access (err u200))
(define-constant error-proposal-not-found (err u201))
(define-constant error-duplicate-vote (err u202))
(define-constant error-voting-period-ended (err u203))
(define-constant error-governance-still-active (err u204))
(define-constant error-invalid-vote-option (err u205))
(define-constant error-invalid-duration (err u206))
(define-constant error-already-finalized (err u207))
(define-constant error-platform-disabled (err u208))

;; Platform State
(define-data-var governance-counter uint u0)
(define-data-var platform-status bool true)

;; Governance Proposals Storage
(define-map governance-proposals
    { proposal-id: uint }
    {
        title: (string-ascii 120),
        description: (string-ascii 600),
        proposer: principal,
        creation-block: uint,
        voting-deadline: uint,
        affirmative-votes: uint,
        negative-votes: uint,
        abstain-votes: uint,
        is-concluded: bool,
        participation-rate: uint
    }
)

;; Vote Records Storage
(define-map vote-ledger
    { proposal-id: uint, voter-address: principal }
    { 
        vote-choice: uint, ;; 0=no, 1=yes, 2=abstain
        timestamp: uint,
        voting-power: uint
    }
)

;; Voter Registry
(define-map voter-registry
    { voter-address: principal }
    {
        total-participations: uint,
        reputation-score: uint,
        last-activity: uint
    }
)

;; Internal Functions
(define-private (verify-admin-privileges)
    (is-eq tx-sender voxchain-admin)
)

(define-private (is-governance-active (proposal-id uint))
    (match (map-get? governance-proposals { proposal-id: proposal-id })
        proposal-data
        (and
            (>= burn-block-height (get creation-block proposal-data))
            (<= burn-block-height (get voting-deadline proposal-data))
            (not (get is-concluded proposal-data))
            (var-get platform-status)
        )
        false
    )
)

(define-private (has-participated (proposal-id uint) (voter principal))
    (is-some (map-get? vote-ledger { proposal-id: proposal-id, voter-address: voter }))
)

(define-private (update-voter-profile (voter-address principal))
    (let ((current-profile (default-to 
                           { total-participations: u0, reputation-score: u0, last-activity: u0 }
                           (map-get? voter-registry { voter-address: voter-address }))))
        (map-set voter-registry
            { voter-address: voter-address }
            {
                total-participations: (+ (get total-participations current-profile) u1),
                reputation-score: (+ (get reputation-score current-profile) u10),
                last-activity: burn-block-height
            }
        )
    )
)

;; Core Governance Functions
(define-public (initiate-governance (title (string-ascii 120)) 
                                  (description (string-ascii 600)) 
                                  (voting-duration uint))
    (let ((new-proposal-id (+ (var-get governance-counter) u1)))
        (asserts! (verify-admin-privileges) error-unauthorized-access)
        (asserts! (> voting-duration u0) error-invalid-duration)
        (asserts! (var-get platform-status) error-platform-disabled)
        
        (map-set governance-proposals
            { proposal-id: new-proposal-id }
            {
                title: title,
                description: description,
                proposer: tx-sender,
                creation-block: burn-block-height,
                voting-deadline: (+ burn-block-height voting-duration),
                affirmative-votes: u0,
                negative-votes: u0,
                abstain-votes: u0,
                is-concluded: false,
                participation-rate: u0
            }
        )
        
        (var-set governance-counter new-proposal-id)
        (print { 
            event: "governance-initiated", 
            proposal-id: new-proposal-id, 
            title: title,
            duration: voting-duration
        })
        (ok new-proposal-id)
    )
)

(define-public (submit-vote (proposal-id uint) (vote-choice uint))
    (let ((proposal-data (unwrap! (map-get? governance-proposals { proposal-id: proposal-id }) 
                                 error-proposal-not-found)))
        (asserts! (is-governance-active proposal-id) error-voting-period-ended)
        (asserts! (not (has-participated proposal-id tx-sender)) error-duplicate-vote)
        (asserts! (<= vote-choice u2) error-invalid-vote-option)
        
        ;; Record the vote
        (map-set vote-ledger
            { proposal-id: proposal-id, voter-address: tx-sender }
            { 
                vote-choice: vote-choice, 
                timestamp: burn-block-height,
                voting-power: u1
            }
        )
        
        ;; Update vote tallies
        (let ((updated-proposal 
               (if (is-eq vote-choice u1)
                   (merge proposal-data { affirmative-votes: (+ (get affirmative-votes proposal-data) u1) })
                   (if (is-eq vote-choice u0)
                       (merge proposal-data { negative-votes: (+ (get negative-votes proposal-data) u1) })
                       (merge proposal-data { abstain-votes: (+ (get abstain-votes proposal-data) u1) })))))
            
            (map-set governance-proposals
                { proposal-id: proposal-id }
                updated-proposal
            )
        )
        
        ;; Update voter profile
        (update-voter-profile tx-sender)
        
        (print { 
            event: "vote-submitted", 
            proposal-id: proposal-id, 
            voter: tx-sender,
            choice: vote-choice
        })
        (ok true)
    )
)

(define-public (conclude-voting (proposal-id uint))
    (let ((proposal-data (unwrap! (map-get? governance-proposals { proposal-id: proposal-id }) 
                                 error-proposal-not-found)))
        (asserts! (verify-admin-privileges) error-unauthorized-access)
        (asserts! (> burn-block-height (get voting-deadline proposal-data)) error-governance-still-active)
        (asserts! (not (get is-concluded proposal-data)) error-already-finalized)
        
        (let ((total-votes (+ (+ (get affirmative-votes proposal-data) 
                                (get negative-votes proposal-data))
                             (get abstain-votes proposal-data))))
            (map-set governance-proposals
                { proposal-id: proposal-id }
                (merge proposal-data { 
                    is-concluded: true,
                    participation-rate: total-votes
                })
            )
        )
        
        (print { 
            event: "voting-concluded", 
            proposal-id: proposal-id,
            result: (> (get affirmative-votes proposal-data) (get negative-votes proposal-data))
        })
        (ok true)
    )
)

;; Query Functions
(define-read-only (fetch-proposal (proposal-id uint))
    (map-get? governance-proposals { proposal-id: proposal-id })
)

(define-read-only (get-voting-stats (proposal-id uint))
    (match (map-get? governance-proposals { proposal-id: proposal-id })
        proposal-data
        (ok {
            affirmative: (get affirmative-votes proposal-data),
            negative: (get negative-votes proposal-data),
            abstain: (get abstain-votes proposal-data),
            total-participation: (+ (+ (get affirmative-votes proposal-data) 
                                     (get negative-votes proposal-data))
                                   (get abstain-votes proposal-data)),
            is-concluded: (get is-concluded proposal-data)
        })
        error-proposal-not-found
    )
)

(define-read-only (verify-participation (proposal-id uint) (voter-address principal))
    (is-some (map-get? vote-ledger { proposal-id: proposal-id, voter-address: voter-address }))
)

(define-read-only (get-user-vote-record (proposal-id uint) (voter-address principal))
    (map-get? vote-ledger { proposal-id: proposal-id, voter-address: voter-address })
)

(define-read-only (get-governance-counter)
    (var-get governance-counter)
)

(define-read-only (is-proposal-active (proposal-id uint))
    (is-governance-active proposal-id)
)

(define-read-only (get-governance-result (proposal-id uint))
    (match (map-get? governance-proposals { proposal-id: proposal-id })
        proposal-data
        (ok {
            proposal-passed: (and 
                            (get is-concluded proposal-data)
                            (> (get affirmative-votes proposal-data) (get negative-votes proposal-data))),
            affirmative-votes: (get affirmative-votes proposal-data),
            negative-votes: (get negative-votes proposal-data),
            abstain-votes: (get abstain-votes proposal-data),
            is-concluded: (get is-concluded proposal-data),
            participation-rate: (get participation-rate proposal-data)
        })
        error-proposal-not-found
    )
)

(define-read-only (get-voter-profile (voter-address principal))
    (map-get? voter-registry { voter-address: voter-address })
)

(define-read-only (get-platform-status)
    (var-get platform-status)
)

;; Administrative Functions
(define-public (toggle-platform-status)
    (begin
        (asserts! (verify-admin-privileges) error-unauthorized-access)
        (var-set platform-status (not (var-get platform-status)))
        (ok (var-get platform-status))
    )
)

;; Platform Initialization
(begin
    (print "VoxChain Governance Platform Initialized")
    (print "Empowering voices through blockchain transparency")
)