#!/usr/bin/perl

use strict;
use warnings;
use utf8;

use Scalar::Util 'blessed';
use Net::Twitter::Lite::WithAPIv1_1;
#use Data::Dumper;
use List::Compare;
use JSON;
use Config::Pit;
use MongoDB;
use MongoDB::OID;

# Config::Pit
my $config = Config::Pit::get("list");

# $list_id, $sender_addressは指定されなかった場合0
my($access_token, $access_token_secret, $screen_name, $mode, $list_id, $sender_address) = @ARGV;
#my $filename = "/var/www/html/list/public/". $screen_name . ".json";

# Net::Twitter::Lite
my $consumer_key = $config->{consumer_key};
my $consumer_secret = $config->{consumer_secret};
my $nt = Net::Twitter::Lite::WithAPIv1_1->new(
	consumer_key => $consumer_key,
	consumer_secret => $consumer_secret,
	ssl => 1
);
$nt->access_token( $access_token );
$nt->access_token_secret( $access_token_secret );

# MongoDB
my $client = MongoDB::MongoClient->new;
my $db = $client->get_database( $config->{data_base} );
my $paste = $db->get_collection(  $config->{collection} );


#メール用メッセージ
#my $MAIL_FAULT_TITLE = "TimeLine Copier Result (faulted)";
my $MAIL_FAULT_MESSAGE = "TimeLine Copierの処理に失敗しました。";
#my $MAIL_PROCESS_TITLE = "TimeLine Copier Result (on process)";
my $MAIL_PROCESS_MESSAGE = "TimeLine Copierの処理が中断されました。15分後に処理を再開します。";
#my $MAIL_SUCCEED_TITLE = "TimeLine Copier Result (succeed)'";
my $MAIL_SUCCEED_MESSAGE = "TimeLine Copierの処理が完了しました。Twitterを確認して下さい。";

###登録失敗してるひとのリストを返す###
sub getFaultedMember {
	my $list_id = shift;
	#my $filename = shift;
	my $mem = shift;
	my $repeat_count = shift;

	my $cursor = -1;
	my $list_members = $nt->list_members({list_id => $list_id, cursor => $cursor});

	my @list_mem;
	for my $a (@{$list_members->{users}}){
		push(@list_mem,$a->{id_str});
	}
	$cursor = $list_members->{next_cursor};
	while ($cursor != 0){
		$list_members = $nt->list_members({list_id => $list_id, cursor => $cursor});
		for my $a (@{$list_members->{users}}){
			push(@list_mem,$a->{id_str});
		}
		$cursor = $list_members->{next_cursor};
	}

	my $lc = List::Compare->new($mem, \@list_mem);
	my @only = $lc->get_Lonly; #登録失敗者リスト

	my $add_faulted_count = @only;
	#JSON出力
	my $mem_count = @list_mem;
#	open(OUT, ">$filename");
#		my %trig = ();
#		$trig{complete} = 0;
#		$trig{repeat} = $repeat_count;
#		$trig{result} = "Processing on ".$mem_count." members (left : ".$add_faulted_count." members)";
#		my $json_out = encode_json(\%trig);
#		print OUT $json_out;
#	close(OUT);
    $paste->update({"screen_name" => $screen_name}, {'$set' => {result => "Processing on ".$mem_count." members (left : ".$add_faulted_count." members)", complete => 1}});
	return @only;
}

#######メイン処理#######
sub mainFunc {
	
	#my $self = shift;
	my $mem = shift;
	my $list_id = shift;

	my $magic = 50; #一度にリストにぶち込む人数
	my $count = @$mem;

	my $hyaku = int($count / $magic);
	my $amari = $count % $magic;

	#割り切れる分の処理
	for(my $i = 0; $i < $hyaku; $i++){
		eval {#この中の処理はエラー無視で進めさせる（無限ループはしないはず）
			my @temp = @$mem[$i*$magic ... (($i+1)*$magic)-1];
			my $str = join(',', @temp);
			$nt->add_list_members({list_id=>$list_id, user_id=>$str});
			sleep 1;
		};
		if( my $err = $@ ){ #ただしAPI切れか404なら死なす
			die $@ unless blessed $err && $err->isa('Net::Twitter::Lite::Error');
			my $error = $err->code;
			if($error == 429 || $error == 404) { die $@; }
		}
	}
	#端数
	if($amari > 0){
		eval {
			my @temp = @$mem[$hyaku*$magic ... $hyaku*$magic+($amari-1)];
			my $str = join(',', @temp);
			$nt->add_list_members({list_id=>$list_id, user_id=>$str});
			sleep 1;
		};
		if( my $err = $@ ){
			die $@ unless blessed $err && $err->isa('Net::Twitter::Lite::Error');
			my $error = $err->code;
			if($error == 429 || $error == 404) { die $@; }
		}
	}

	return;
}

#処理開始JSON出力
#open(OUT, ">$filename");
#	my %trig = ();
#	$trig{complete} = 0;
#	$trig{result} = "Processing ...";
#	my $json_out = encode_json(\%trig);
#	print OUT $json_out;
#close(OUT);

$paste->update({"screen_name" => $screen_name}, {'$set' => {result => 'Processing...', complete => 1}});

#my $list_id; #リストID
my @mem = (); #リスト登録対象

eval{
	my $hash;
	if($mode eq 'follower'){
		$hash = $nt->followers_ids({count=>4999, stringify_ids =>'true'});
	}
	else {
		$hash = $nt->friends_ids({count=>4999, stringify_ids=>'true'});
	}
	@mem = @{$hash->{ids}};

	#差分処理モード判定
	if( $list_id ){#既存リスト追記モード
		my @only = &getFaultedMember($list_id, \@mem, 0);
		sleep 1;

		#リストとの差分
		@mem = ();
		@mem = @only;

		$nt->update_list({list_id => $list_id, description => "It\'s processing." });
		sleep 2;
	}
	else{
		my $list = $nt->create_list({name=>'home_timeline_copy', mode=>'private', description =>"It\'s processing." });
		$list_id = $list->{id_str};
		sleep 2;
	}

	#自分を入れておく
	$nt->add_list_member({list_id=>$list_id, screen_name=>$screen_name});
};
if( my $err = $@ ){
	#unlink($filename);
    die $@ unless blessed $err && $err->isa('Net::Twitter::Lite::Error');
    my $error_code = $err->code;
    my $error_message = $err->error;
	if($sender_address){
		eval {
			$nt->new_direct_message({user=>$screen_name, text=>$MAIL_FAULT_MESSAGE."\n".$@});
		};
		if($@) { warn ("[err_dm] ".$screen_name." : ". $@ . "\n"); }
	}
    $paste->update({"screen_name" => $screen_name}, {'$set' => {result => $error_message, complete => $error_code}});
	exit 1;
}

my $error_count = 0; #APIエラー発生回数

my $add_faulted_count = -1; #リスト登録に失敗した人数
my $repeat_count = 0; #ループ回数
my $REPEAT_MAGIC = 2; #この回数以上リピートしたらループを切る

while ($add_faulted_count != 0 && $repeat_count < $REPEAT_MAGIC) {
	eval {
		my $temp_add_faulted_count = $add_faulted_count;

		#メイン処理
		&mainFunc(\@mem, $list_id);

		#リストに登録できた勢を計算する
		my @only = &getFaultedMember($list_id, \@mem, $repeat_count);
		$add_faulted_count = @only;

		#無限ループしそう判定
		if($add_faulted_count >= $temp_add_faulted_count) {$repeat_count++;}

		@mem = ();
		@mem = @only;
	};
	if( my $err = $@ ){
        # Twitter Errorじゃない場合おかしい使い方をされているので400で落とす。
		unless (blessed $err && $err->isa('Net::Twitter::Lite::Error')) {
            $paste->update({"screen_name" => $screen_name}, {'$set' => {result => "You sent Bad Request.", complete =>400 }});
            warn ("[err_unknown] ".$screen_name." : ". $@ . "\n");
            exit 1;
        }
		my $error = $err->code;
        my $error_message = $err->error;
		$error_count++;

		#一回目のエラー、かつ404じゃないなら再開する
		if($sender_address && $error_count == 1 && $error != 404){
			eval {
				$nt->new_direct_message({user=>$screen_name, text=>$MAIL_PROCESS_MESSAGE."\n".$@});
			};
			if($@) { warn ("[err_dm] ".$screen_name." : ". $@ . "\n"); }
			sleep 900;
			next;
		}

		#失敗しました。手の施しようがない
		#unlink($filename);
		if($sender_address) {
			eval {
				$nt->new_direct_message({user=>$screen_name, text=>$MAIL_FAULT_MESSAGE ."\n".$@});
			};
			if($@) { warn ("[err_dm] ".$screen_name." : ". $@ . "\n"); }
		}
		warn ("[err] ".$screen_name." : ". $@ . "\n");
		$paste->update({"screen_name" => $screen_name}, {'$set' => {result => $error_message, complete => $error}});
        eval {
		  $nt->update_list({list_id => $list_id, description => "error : ".$@});
        };
        if($@) { warn ("[err_update] ".$screen_name." : ". $@. "\n"); }
		exit 1;
	}
}

#無限ループしそうになった
my $ADD_FAULT_MESSAGE = $add_faulted_count."名の存在しない・凍結された可能性のあるユーザをリストに登録できませんでした。Twitterを確認して下さい。";
if($repeat_count >= $REPEAT_MAGIC) {
	#unlink($filename);
	if($sender_address){
		eval {
			$nt->new_direct_message({user=>$screen_name, text=>$ADD_FAULT_MESSAGE});
		};
		if($@) { warn ("[err_dm] ".$screen_name." : ". $@); }
	}
    eval { 
	   $nt->update_list({list_id => $list_id, description => $ADD_FAULT_MESSAGE});
    };
    if($@) { warn ("[err_update] ".$screen_name." : ". $@. "\n"); }
    $paste->update({"screen_name" => $screen_name}, {'$set' => {result => $ADD_FAULT_MESSAGE, complete => -2}});
    print ("[info] " .$screen_name." : ". $ADD_FAULT_MESSAGE. "\n");
	exit 1;
}

#処理完了
#unlink($filename);
if($sender_address){
	eval {
		$nt->new_direct_message({user=>$screen_name, text=>$MAIL_SUCCEED_MESSAGE});
	};
	if($@) { warn ("[err_dm] ".$screen_name." : ". $@ . "\n"); }
}
eval { 
    $nt->update_list({list_id => $list_id, description => "succeed"});
};
if($@) { warn ("[err_update] ".$screen_name." : ". $@. "\n"); }
$paste->update({"screen_name" => $screen_name}, {'$set' => {result => "リストの作成が完了しました", complete => 200}});
print ("[info] " .$screen_name." : complete.\n");
exit 0;
