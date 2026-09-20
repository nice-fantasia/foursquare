BEGIN;

SET LOCAL lock_timeout = '5s';

ALTER TABLE "Match"
ADD COLUMN "contentHash" TEXT,
ADD COLUMN "player1Color" TEXT NOT NULL DEFAULT 'black',
ADD COLUMN "player2Color" TEXT NOT NULL DEFAULT 'white',
ADD COLUMN "winnerColor" TEXT,
ADD COLUMN "startedAt" TIMESTAMP(3);

UPDATE "Match"
SET
    "contentHash" = 'legacy:' || "externalId",
    "winnerColor" = CASE
        WHEN "winnerId" = "player1Id" THEN "player1Color"
        WHEN "winnerId" = "player2Id" THEN "player2Color"
        ELSE 'draw'
    END,
    "startedAt" = "createdAt";

ALTER TABLE "Match"
ALTER COLUMN "contentHash" SET NOT NULL,
ALTER COLUMN "player1Color" DROP DEFAULT,
ALTER COLUMN "player2Color" DROP DEFAULT,
ALTER COLUMN "winnerColor" SET NOT NULL,
ALTER COLUMN "startedAt" SET NOT NULL;

CREATE TABLE "MatchOutbox" (
    "id" TEXT NOT NULL,
    "matchId" TEXT NOT NULL,
    "contentHash" TEXT NOT NULL,
    "payloadJson" TEXT NOT NULL,
    "attemptCount" INTEGER NOT NULL DEFAULT 0,
    "availableAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "leaseToken" TEXT,
    "leaseExpiresAt" TIMESTAMP(3),
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updatedAt" TIMESTAMP(3) NOT NULL,
    CONSTRAINT "MatchOutbox_pkey" PRIMARY KEY ("id")
);

CREATE UNIQUE INDEX "MatchOutbox_matchId_key"
ON "MatchOutbox"("matchId");

CREATE INDEX "MatchOutbox_availableAt_createdAt_idx"
ON "MatchOutbox"("availableAt", "createdAt");

CREATE INDEX "MatchOutbox_leaseExpiresAt_idx"
ON "MatchOutbox"("leaseExpiresAt");

COMMIT;
