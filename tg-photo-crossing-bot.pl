#!/usr/bin/env perl
use v5.18;
use strict;
use warnings;

use Path::Tiny qw(path);
use List::Util qw(max);
use List::UtilsBy qw(max_by);
use Getopt::Long qw(GetOptions);
use Mojo::JSON qw(encode_json decode_json);
use Mojo::IOLoop;
use Mojo::Util;
use Mojo::UserAgent;

use DBI;
use DBD::SQLite;

use WWW::Telegram::BotAPI;
my $CONTEXT = {
    db => "",
};

sub dbh_rw {
    return DBI->connect("dbi:SQLite:dbname=". $CONTEXT->{db}, "", "");
}

sub db_store_photo {
    my ($chat_id, $file_id) = @_;
    dbh_rw()->do("INSERT INTO photos (`chat_id`, `file_id`) VALUES (?,?)", {}, $chat_id, $file_id);
}

sub db_get_photo {
    my ($chat_id) = @_;
    my ($count) = dbh_rw()->selectrow_array("SELECT count(*) FROM photos");
    my $o = int rand($count);
    my ($file_id) = dbh_rw()->selectrow_array("SELECT `file_id` FROM photos LIMIT 1 OFFSET $o");
    return $file_id;
}

sub tg_get_updates {
    return unless $CONTEXT->{tg_bot};
    state $max_update_id = 0;

    my $tgbot = $CONTEXT->{tg_bot};
    $tgbot->api_request(
        'getUpdates',
        { $max_update_id ? (offset => 1+$max_update_id) : () },
        sub {
            my ($ua, $tx) = @_;
            if ($tx->success) {
                my $res = $tx->res->json;
                return unless $res->{ok} && @{$res->{result}};

                for my $m (@{$res->{result}}) {
                    $max_update_id = max($max_update_id, $m->{update_id});
                    if (exists $m->{message}{photo}) {
                        my $photo = max_by { $_->{width} } @{ $m->{message}{photo} };
                        my $chat_id = $m->{message}{chat}{id};
                        my $file_id = $photo->{file_id};

                        db_store_photo($chat_id, $file_id);
                        tg_reply_with_a_photo($chat_id);
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

sub tg_reply_with_a_photo {
    my ($chat_id) = @_;
    return unless $CONTEXT->{tg_bot};
    my $photo = db_get_photo($chat_id);
    $CONTEXT->{tg_bot}->api_request(
        'sendPhoto',
        { chat_id => $chat_id, photo => $photo },
        sub {
            my ($ua, $tx) = @_;
            say "Replied => $chat_id";
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
        if ($tx->success) {
            my $r = $tx->res->json;
            Mojo::Util::dumper(['getMe', $r]);
            tg_get_updates();
            Mojo::IOLoop->recurring( 15, \&tg_get_updates );
        } else {
            Mojo::Util::dumper(['getMe Failed.', $tx->res->body]);
            Mojo::IOLoop->timer( 5 => sub { $tgbot->api_request(getMe => $get_me_cb) });
        } 
    };

    Mojo::IOLoop->timer( 5 => sub { $tgbot->api_request(getMe => $get_me_cb) });
    return $tgbot;
}

sub MAIN {
    my (%args) = @_;
    die("Missing mandatory parameter: --db") unless -f $args{db};

    $CONTEXT->{db} = $args{db};
    my $tmpdir = $ENV{TMPDIR} // "/tmp";
    $CONTEXT->{download_dir} = $args{download_dir} // "${tmpdir}/tg-photo-crossing-bot";
    $CONTEXT->{tg_bot} = tg_init( $args{telegram_token} );

    Mojo::IOLoop->start;
}

my %args;
GetOptions(
    \%args,
    "telegram_token=s",
    "download_dir=s",
    "db=s",
);
MAIN(%args);

__END__

CREATE TABLE photos(`chat_id` UNSIGNED INTEGER, `file_id` UNSIGNED INTEGER);
CREATE UNIQUE INDEX photos_chat_file ON photos (`chat_id`, `file_id`);

