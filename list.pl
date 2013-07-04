#!/usr/bin/perl

use strict;
use warnings;
use utf8;

use Net::Twitter::Lite::WithAPIv1_1;
use Mojolicious::Lite;

my $consumer_key ="***";
my $consumer_secret = "***";

my $nt = Net::Twitter::Lite::WithAPIv1_1->new(
	consumer_key => $consumer_key,
	consumer_secret => $consumer_secret,
);

# Display top page
get '/' => sub {
	my $self = shift;
	my $access_token = $self->session( 'access_token' ) || '';
	my $access_token_secret = $self->session( 'access_token_secret' ) || '';
	my $screen_name = $self->session( 'screen_name' ) || '';

	# セッションにaccess_token/access_token_secretが残ってなければ認証処理へ
	return $self->redirect_to( 'https://retrorocket.biz/list/auth.cgi' ) unless ($access_token && $access_token_secret);
	$self->stash('name' => $screen_name);

} => 'index';

post '/list' => sub {

	my $self = shift;

	my $access_token = $self->session( 'access_token' ) || '';
	my $access_token_secret = $self->session( 'access_token_secret' ) || '';
	my $screen_name = $self->session( 'screen_name' ) || '';

	# セッションにaccess_tokenが残ってなければ再認証
	#return $self->redirect_to( 'index' ) unless ($access_token && $access_token_secret);
	return  $self->render_json({'result' => "Not Authorized"}) unless ($access_token && $access_token_secret);

	$nt->access_token( $access_token );
	$nt->access_token_secret( $access_token_secret );

	my $list = $nt->create_list({name=>'home_timeline_copy', mode=>'private'});
	my $num = $list->{id_str};
	my $hash = $nt->friends_ids({count=>4999});
	my @mem = @{$hash->{ids}};

	my $magic = 50;
	my $count = @mem;
	#print $count;
	my $hyaku = int($count / $magic);
	my $amari = $count % $magic;
	eval {

		my $i = 0;
		for($i = 0; $i < $hyaku; $i++){
			my @temp = @mem[$i*$magic ... (($i+1)*$magic)-1];
			my $str = join(',', @temp);
			#print $str;
			$nt->add_list_members({list_id=>$num, user_id=>$str});
			sleep 1;
		}

		if($amari > 0){
			my @temp = @mem[$hyaku*$magic ... $hyaku*$magic+($amari-1)];
			my $str = join(',', @temp);
			#print $str;
			$nt->add_list_members({list_id=>$num, user_id=>$str});
		}
		$nt->add_list_member({list_id=>$num, screen_name=>$screen_name});
	};
	if($@){
		$self->session( expires => 1 );
		return  $self->render_json({'result' => $@ . "：処理途中で終了しました"});
	}
	$self->session( expires => 1 );
	return  $self->render_json({'result' => "処理が完了しました"});
	#セッション削除
	#$self->render;

} => 'list';

# Session削除
get '/logout' => sub {
	my $self = shift;
	$self->session( expires => 1 );
	#$self->render;
} => 'logout';

app->sessions->secure(1);
app->secret("***"); # セッション管理のために付けておく
app->start;

