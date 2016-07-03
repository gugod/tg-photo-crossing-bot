#!/usr/bin/env perl
use v5.18;
use strict;
use warnings;

use Data::Printer;

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
    file_queue => [],
    known_photos => [],
    db => "",
};

sub dbh_rw {
    return $CONTEXT->{dbh} ||= DBI->connect("dbi:SQLite:dbname=". $CONTEXT->{db}, "", "");
}

sub db_store_photo {
    my ($chat_id, $file_id) = @_;
    push @{$CONTEXT->{known_photos}}, $file_id;
    dbh_rw()->do("INSERT INTO photos (`chat_id`, `file_id`) VALUES (?,?)", {}, $chat_id, $file_id);
}

sub db_get_photo {
    my ($chat_id) = @_;
    my $dbh = dbh_rw();
    my ($count) = $dbh->selectrow_array("SELECT count(*) FROM photos");
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

                        tg_reply_with_a_photo($m->{message}{chat}{id});

                        push @{ $CONTEXT->{file_queue} }, {
                            file_id => $photo->{file_id},
                            chat_id => $m->{message}{chat}{id}
                        };
                    } else {
                        # say "No photo: " . encode_json($m);
                    }
                }
            } else {
                say "getUpdates failed: " . Mojo::Util::dumper( $tx->error );
            }
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

sub download_and_store_file {
    my ($tgbot, $token, $download_dir);
    
    return unless ($token = $CONTEXT->{tg_token}) && ($tgbot = $CONTEXT->{tg_bot}) && ($download_dir = $CONTEXT->{download_dir}) && @{$CONTEXT->{file_queue}};


    my $x = pop(@{$CONTEXT->{file_queue}});
    my $file_id = $x->{file_id};
    my $chat_id = $x->{chat_id};

    db_store_photo($chat_id, $file_id);

    $tgbot->api_request(
        'getFile',
        { file_id => $file_id },
        sub {
            my ($ua, $tx) = @_;
            my $r = $tx->res->json;
            if ($r->{ok}) {
                my $file_path = $r->{result}{file_path};
                my $file_url = "https://api.telegram.org/file/bot${token}/${file_path}";
                my ($file_ext) = ($file_path) =~ m{ \. ([^\.]+) \z}x;

                my $shard = 0;
                my $download_path = path("${download_dir}/${shard}/${file_id}.${file_ext}");
                $download_path->parent()->mkpath();

                Mojo::UserAgent->new->max_redirects(5)->get($file_url)->res->content->asset->move_to( "". $download_path );
            }
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
    Mojo::IOLoop->recurring( 1 => \&download_and_store_file );

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

