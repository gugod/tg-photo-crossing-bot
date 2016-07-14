#!/usr/bin/env perl
use v5.18;
use strict;
use warnings;

use List::Util qw(max);
use List::UtilsBy qw(max_by);
use Getopt::Long qw(GetOptions);
use Mojo::IOLoop;
use Mojo::Util;
use Mojo::UserAgent;

use DBI;
use DBD::SQLite;

use WWW::Telegram::BotAPI;
my $CONTEXT = {
    db => "",
};

use constant MESSAGE_PHOTO_DUPLICATED => "alas, I've seen that picture before. Give me another one please :)";

sub dbh_rw {
    return DBI->connect("dbi:SQLite:dbname=". $CONTEXT->{db}, "", "");
}

sub db_find_or_create_chat_id {
    my ($tg_chat_id) = @_;
    my $dbh = dbh_rw();
    my ($id) = $dbh->selectrow_array("SELECT id FROM chats WHERE tg_chat_id = ?", undef, $tg_chat_id);
    unless ($id) {
        ($id) = $dbh->selectrow_array("SELECT max(id) FROM chats");
        $id //= 0;
        $id +=  1;
        $dbh->do("INSERT INTO chats(`id`, `tg_chat_id`) VALUES (?,?)", {}, $id, $tg_chat_id);
    }
    return $id;
}

sub db_find_photo_id {
    my ($tg_file_id) = @_;
    my $dbh = dbh_rw();
    my ($id) = $dbh->selectrow_array("SELECT id FROM photos WHERE tg_file_id = ?", {}, $tg_file_id);
    return $id;
}

sub db_insert_photo {
    my ($tg_file_id) = @_;
    my $dbh = dbh_rw();
    my ($id) = $dbh->selectrow_array("SELECT id FROM photos WHERE tg_file_id = ?", undef, $tg_file_id);
    unless ($id) {
        ($id) = $dbh->selectrow_array("SELECT max(id) FROM photos");
        $id //= 0;
        $id +=  1;
        $dbh->do("INSERT INTO photos(`id`, `tg_file_id`) VALUES (?,?)", {}, $id, $tg_file_id);
    }
    return $id;
}

sub db_store_photos_sent {
    my ($chat_id, $photo_id) = @_;
    my $dbh = dbh_rw();
    $dbh->do("INSERT INTO photos_sent (`chat_id`, `photo_id`) VALUES (?,?)", {}, $chat_id, $photo_id);
}

sub db_store_photos_received {
    my ($chat_id, $photo_id) = @_;
    my $dbh = dbh_rw();
    $dbh->do("INSERT INTO photos_received (`chat_id`, `photo_id`) VALUES (?,?)", {}, $chat_id, $photo_id);
}

sub db_get_tg_file_id {
    my ($photo_id) = @_;
    my ($tg_file_id) = dbh_rw()->selectrow_array("SELECT tg_file_id FROM photos WHERE id = ?", {}, $photo_id);
    return $tg_file_id;
}

sub db_get_unseen_photo {
    my ($chat_id) = @_;
    my $dbh = dbh_rw();
    my $photo_id;
    my ($max_photo_id) = $dbh->selectrow_array("SELECT max(id) FROM photos");
    my $seen = 1;
    my $count = 0;
    while($count++ < 2 && (!$photo_id || $seen)) {
        my $o = int rand($max_photo_id);
        ($photo_id) = $dbh->selectrow_array("SELECT `id` FROM photos WHERE id = ?", undef, $o);
        next unless $photo_id;

        ($seen) = $dbh->selectrow_array("SELECT 1 FROM photos_sent WHERE chat_id = ? AND photo_id = ?", {}, $chat_id, $photo_id);
        if (!$seen) {
            ($seen) = $dbh->selectrow_array("SELECT 1 FROM photos_received WHERE chat_id = ? AND photo_id = ?", {}, $chat_id, $photo_id);
        }
    }
    unless ($photo_id) {
        say "exausted, give a default photo id.";
        $photo_id //= 1;
    }
    return $photo_id;
}

sub db_store_sent_photo {
    my ($chat_id, $file_id) = @_;
    dbh_rw()->do("INSERT INTO sent_photos (`chat_id`, `file_id`) VALUES (?,?)", {}, $chat_id, $file_id);
}

sub tg_get_updates {
    return unless $CONTEXT->{tg_bot};
    state $max_update_id = 0;

    say "Getting tg updates...";
    my $tgbot = $CONTEXT->{tg_bot};
    $tgbot->api_request(
        'getUpdates',
        { timeout => 15, $max_update_id ? (offset => 1+$max_update_id) : () },
        sub {
            my ($ua, $tx) = @_;
            say "Cool";
            if ($tx->success) {
                my $res = $tx->res->json;
                return unless $res->{ok} && @{$res->{result}};

                for my $m (@{$res->{result}}) {
                    $max_update_id = max($max_update_id, $m->{update_id});
                    if (exists $m->{message}{photo}) {
                        my $photo = max_by { $_->{width} } @{ $m->{message}{photo} };
                        my $tg_chat_id = $m->{message}{chat}{id};
                        my $tg_file_id = $photo->{file_id};

                        my $chat_id = db_find_or_create_chat_id($tg_chat_id);
                        my $photo_id = db_find_photo_id($tg_file_id);
                        if ($photo_id) {
                            tg_reply_with_message($tg_chat_id, MESSAGE_PHOTO_DUPLICATED);
                        } else {
                            my $photo_id_to_send = db_get_unseen_photo($chat_id);

                            $photo_id = db_insert_photo($tg_file_id);
                            db_store_photos_received($chat_id, $photo_id);

                            my $tg_file_id = db_get_tg_file_id($photo_id_to_send);
                            tg_reply_with_photo(
                                $tg_chat_id,
                                $tg_file_id,
                                sub {
                                    db_store_photos_sent($chat_id, $photo_id);
                                }
                            );
                        }
                    } else {
                        tg_reply_with_usage($m->{message}{chat}{id});
                    }
                }
            } else {
                say "getUpdates failed: " . Mojo::Util::dumper( $tx->error );
            }
        }
    );
}

sub tg_reply_with_message {
    my ($tg_chat_id, $message_text) = @_;
    return unless $CONTEXT->{tg_bot};
    $CONTEXT->{tg_bot}->api_request(
        'sendMessage',
        { chat_id => $tg_chat_id, text => $message_text },
        sub {
            my ($ua, $tx) = @_;
            say "Replied message => $tg_chat_id => $message_text";
        }
    );
}

sub tg_reply_with_usage {
    my ($chat_id) = @_;
    return unless $CONTEXT->{tg_bot};
    my $usage = "Send me nice photo you took, I'll send you a nice one back. \x{1F638}";
    $CONTEXT->{tg_bot}->api_request(
        'sendMessage',
        { chat_id => $chat_id, text => $usage },
        sub {
            my ($ua, $tx) = @_;
            say "Replied usage => $chat_id";
        }
    );
}

sub tg_reply_with_photo {
    my ($tg_chat_id, $tg_file_id, $cb) = @_;
    return unless $CONTEXT->{tg_bot};
    $CONTEXT->{tg_bot}->api_request(
        'sendPhoto',
        { chat_id => $tg_chat_id, photo => $tg_file_id },
        sub {
            my ($ua, $tx) = @_;
            say "Replied => $tg_chat_id => $tg_file_id";
            $cb->() if $cb;
        }
    );
}

sub tg_init {
    my ($token) = @_;
    $CONTEXT->{tg_token} = $token;

    my $tgbot = WWW::Telegram::BotAPI->new( token => $token, async => 1 );

    my $get_me_cb;
    $get_me_cb = sub  {
        my ($ua, $tx) = @_;
        say "Hey";
        if ($tx->success) {
            my $r = $tx->res->json;
            Mojo::Util::dumper(['getMe', $r]);
	    tg_get_updates();
            Mojo::IOLoop->recurring( 5, \&tg_get_updates );
        } else {
            Mojo::Util::dumper(['getMe Failed.', $tx->res->body]);
            Mojo::IOLoop->timer( 5 => sub { $tgbot->api_request(getMe => $get_me_cb) });
        } 
    };

    Mojo::IOLoop->timer( 15 => sub { $tgbot->api_request(getMe => $get_me_cb) });
    $CONTEXT->{tg_bot} = $tgbot;
    return $tgbot;
}

sub MAIN {
    my (%args) = @_;
    die("Missing mandatory parameter: --db") unless -f $args{db};

    $CONTEXT->{db} = $args{db};

    tg_init( $args{telegram_token} );

    Mojo::IOLoop->start;
}

my %args;
GetOptions(
    \%args,
    "telegram_token=s",
    "db=s",
);
MAIN(%args);

__END__
