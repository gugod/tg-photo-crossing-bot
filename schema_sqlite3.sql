
CREATE TABLE photos (`id` UNSIGNED INTEGER, `tg_file_id` VARCHAR(128));
CREATE UNIQUE INDEX photos__id ON photos (`id`);

CREATE TABLE chats (`id` UNSIGNED INTEGER, `tg_chat_id` VARCHAR(128));
CREATE UNIQUE INDEX chats__id ON photos (`id`);

CREATE TABLE photos_received(`photo_id` UNSIGNED INTEGER, `chat_id` UNSIGNED INTEGER);
CREATE UNIQUE INDEX photos_received__photo_id__chat_id ON photos_received (`photo_id`, `chat_id`);

CREATE TABLE photos_sent(`photo_id` UNSIGNED INTEGER, `chat_id` UNSIGNED INTEGER);
CREATE UNIQUE INDEX photos_sent__photo_id__chat_id ON photos_received (`photo_id`, `chat_id`);
