// Platform-owned (not part of the T4.2 sync): create the application user that
// component services connect as, instead of the root account.
//
// Runs once, on first start of an empty data volume, before 10-t42-init.js
// (docker-entrypoint-initdb.d executes scripts in lexical order). Credentials
// come from the dnavio-datastores Secret via the container environment.

const appDb = process.env.MONGO_APP_DATABASE;

db.getSiblingDB(appDb).createUser({
  user: process.env.MONGO_APP_USERNAME,
  pwd: process.env.MONGO_APP_PASSWORD,
  roles: [{ role: 'readWrite', db: appDb }],
});

print(`dnavio: application user created for database '${appDb}'`);
