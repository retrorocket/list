#!/usr/bin/perl

use strict;
use warnings;
use utf8;

use Net::Twitter::Lite::WithAPIv1_1;
use Mojolicious::Lite;
#use Data::Dumper;
use Config::Pit;

# Config::Pit
my $config = Config::Pit::get("list");

app->config(
	hypnotoad => {
		listen => ['http://*:'.$config->{port}],
	},
);
app->hook('before_dispatch' => sub {
		my $self = shift;
		if ($self->req->headers->header('X-Forwarded-Host')) {
			#Proxy Path setting
			my $path = shift @{$self->req->url->path->parts};
			push @{$self->req->url->base->path->parts}, $path;
		}
	});


# Net::Twitter::Lite
my $consumer_key = $config->{consumer_key};
my $consumer_secret = $config->{consumer_secret};

my $nt = Net::Twitter::Lite::WithAPIv1_1->new(
	consumer_key => $consumer_key,
	consumer_secret => $consumer_secret,
	ssl => 1
);

# index
get '/' => sub {
	my $self = shift;

	my $access_token = $self->session( 'access_token' ) || '';
	my $access_token_secret = $self->session( 'access_token_secret' ) || '';
	my $screen_name = $self->session( 'screen_name' ) || '';

	#セッションにトークンが残っていない
	return $self->redirect_to( 'http://retrorocket.biz/list' ) unless ($access_token && $access_token_secret);

	$self->stash('name' => $screen_name);

	#my $mail_mode = $self->session('mail') || '';
	my $diff_mode = $self->session('diff') || '';

	#if($mail_mode && $diff_mode) {return $self->render('diff_mail');}
	if($diff_mode) {return $self->render('diff');}
	#if($mail_mode) {return $self->render('mail');}

} => 'index';

get '/auth' => sub {
	my $self = shift;

	my $mode = $self->param('mode') || '';
	my $mail = $self->param('mail') || '';
	my $diff = $self->param('diff') || '';

	$self->session( mode => $mode );
	$self->session( mail => $mail );
	$self->session( diff => $diff );

	my $cb_url = $self->url_for('auth_cb')->to_abs->scheme('https');
	my $url = $nt->get_authorization_url( callback => $cb_url );

	$self->session( token => $nt->request_token );
	$self->session( token_secret => $nt->request_token_secret );

	$self->redirect_to( $url );
} => 'auth';

get '/auth_cb' => sub {
	my $self = shift;

	my $verifier = $self->param('oauth_verifier') || '';
	my $token = $self->session('token') || '';
	my $token_secret = $self->session('token_secret') || '';

	$nt->request_token( $token );
	$nt->request_token_secret( $token_secret );

	# Access token取得
	my ($access_token, $access_token_secret, $user_id, $screen_name)
		= $nt->request_access_token( verifier => $verifier );

	# Sessionに格納
	$self->session( access_token => $access_token );
	$self->session( access_token_secret => $access_token_secret );
	$self->session( screen_name => $screen_name );

	$self->redirect_to( $self->url_for('index')->to_abs->scheme('https') );
} => 'auth_cb';

get '/list_get' => sub {
	my $self = shift;
	my $access_token = $self->session( 'access_token' ) || '';
	my $access_token_secret = $self->session( 'access_token_secret' ) || '';
	my $screen_name = $self->session( 'screen_name' ) || '';
	return $self->render(json =>{'result' => "fault", 'complete' => -1}) unless ($access_token && $access_token_secret);

	$nt->access_token( $access_token );
	$nt->access_token_secret( $access_token_secret );

	eval{	
		my $lists = $nt->get_lists();
		my $lists_num = @$lists;
		if($lists_num == 0) { return $self->render(json =>{'result' => "fault", 'complete' => -1}); }

		my @get_list=();
		foreach my $elem (@$lists){
			my %trig = ();
			$trig{list_name} = $elem->{name};
			$trig{list_id} = $elem->{id_str};
			push(@get_list,\%trig);
		}
		return $self->render(json =>{'result' => "complete", 'complete' => \@get_list});
	};
	if($@){
		return $self->render(json =>{'result' => "fault", 'complete' => -1});
	}

} => 'list_get';

post '/list' => sub {

	my $self = shift;

	#Twitter API
	my $access_token = $self->session( 'access_token' ) || '';
	my $access_token_secret = $self->session( 'access_token_secret' ) || '';
	my $screen_name = $self->session( 'screen_name' ) || '';

	#各種モード判定
	my $mode = $self->session('mode') || "following";
	my $sender_address = $self->session('mail') || 0;
	my $list_id = $self->param('list_id') || 0;

	#トークンなし
	unless ($access_token && $access_token_secret) {
		return $self->render(json =>{'result' => "fault", 'complete' => -1});
	}

	$nt->access_token( $access_token );
	$nt->access_token_secret( $access_token_secret );

	#JSON出力用パス＆処理開始前判定
	my $filename = app->home. "/public/".$screen_name.".json";
	if( -f $filename ) {
		return $self->render(json =>{'result' => "fault", 'complete' => -2});
	}
	#$access_token, $access_token_secret, $screen_name, $mode, $list_id, $sender_address
	system("/home/".$config->{user} ."/perl/list_script.pl ". $access_token . " " . $access_token_secret . " " . $screen_name
		. " " . $mode . " " . $list_id . " " . $sender_address ." &>> /var/www/html/list/log/list.log &");
	$self->session( expires => 1 );
	return $self->render(json =>{'result' => $screen_name, 'complete' => 0 });

} => 'list';

# セッション消去
get '/logout' => sub {
	my $self = shift;
	$self->session( expires => 1 );
	return $self->render(json =>{'result' => "logout"});
} => 'logout';

app->sessions->secure(1);
app->secrets([$config->{session_name}]); # セッション管理のために付けておく
app->start;
