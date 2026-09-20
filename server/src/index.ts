import 'dotenv/config';

import { ConfigurationError, loadServerConfig } from './config';
import { createServerRuntime } from './runtime/server_runtime';
import { createDatabaseService } from './services/database';

const main = async (): Promise<void> => {
    const config = loadServerConfig();
    const database = createDatabaseService(config.databaseUrl);
    const runtime = createServerRuntime(config, {
        database,
        outboxRepository: database,
    });
    const address = await runtime.start();

    console.log(`Server is running on port ${address.port}`);

    const shutdown = (): void => {
        void runtime.shutdown().catch(() => {
            console.error('Server shutdown failed');
            process.exitCode = 1;
        });
    };
    process.once('SIGTERM', shutdown);
    process.once('SIGINT', shutdown);
};

void main().catch((error: unknown) => {
    console.error(
        error instanceof ConfigurationError
            ? error.message
            : 'Server startup failed',
    );
    process.exitCode = 1;
});
